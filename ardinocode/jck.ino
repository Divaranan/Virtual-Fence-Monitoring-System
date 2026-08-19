// ============================================================
// SmartHerd - ESP8266 NodeMCU
// GPS + IMU Sensor Fusion (Dead Reckoning) + Virtual Fence
// NEO-6M GPS + MPU6050 + Active Buzzer
// ============================================================
// Pins:
//   GPS    : RX=D5, TX=D6
//   Buzzer : D7
//   MPU6050: SDA=D2, SCL=D1 | AD0=GND (0x68)
// ============================================================
// SIMPLIFIED VERSION — no database/history/ThingSpeak. Only two
// pieces of live data leave the device: GPS location and gyro/
// activity data, via /gps and /activity. Fence + buzzer safety
// logic runs entirely on-device, independent of the phone being
// connected. LittleFS is used only to persist the active fence
// across reboots (including the self-healing low-heap watchdog
// reboot below) — no history log, no buffered records at all.
// ============================================================

#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <WiFiClient.h>
#include <LittleFS.h>
#include <SoftwareSerial.h>
#include <TinyGPS++.h>
#include <Wire.h>
#include <math.h>

// ── WiFi ────────────────────────────────────────────────────
const char* AP_SSID = "SmartHerd_Collar";
const char* AP_PASS = "12345678";

// ── Security ────────────────────────────────────────────────
const char* DEVICE_KEY = "SmartHerd2026";

// ── Pins ────────────────────────────────────────────────────
#define GPS_RX_PIN D6
#define GPS_TX_PIN D5
#define BUZZER_PIN D7

// ── Battery monitoring ─────────────────────────────────────
#define BATTERY_DIVIDER_RATIO 4.03f
#define BATTERY_SAMPLE_INTERVAL_MS 10000
float batteryVoltage = 0.0f;
unsigned long lastBatterySample = 0;

void sampleBatteryVoltage() {
  int raw = analogRead(A0);
  float pinVoltage = (raw / 1023.0f) * 1.0f;
  batteryVoltage = pinVoltage * BATTERY_DIVIDER_RATIO;
}

// ── Objects ─────────────────────────────────────────────────
SoftwareSerial gpsSerial(GPS_RX_PIN, GPS_TX_PIN);
TinyGPSPlus gps;
ESP8266WebServer server(80);

bool isAuthorised() {
  return server.hasArg("key") && server.arg("key") == String(DEVICE_KEY);
}

// ============================================================
// GPS KALMAN FILTER
// ============================================================
struct GPSKalman {
  double q = 0.000000005;
  double r = 0.000000004;
  double p = 1.0;
  double x = 0.0;
  bool initialized = false;

  double update(double measurement) {
    if (!initialized) { x = measurement; initialized = true; return x; }
    p = p + q;
    double k = p / (p + r);
    x = x + k * (measurement - x);
    p = (1 - k) * p;
    return x;
  }
};

GPSKalman kalmanLat;
GPSKalman kalmanLon;

// ============================================================
// MPU6050 KALMAN FILTER (roll/pitch)
// ============================================================
class KalmanFilter {
  private:
    float Q_angle   = 0.001f;
    float Q_bias    = 0.003f;
    float R_measure = 0.03f;
    float angle     = 0.0f;
    float bias      = 0.0f;
    float P[2][2]   = {{0, 0}, {0, 0}};
  public:
    float getAngle(float newAngle, float newRate, float dt) {
      float rate = newRate - bias;
      angle += dt * rate;
      P[0][0] += dt * (dt*P[1][1] - P[0][1] - P[1][0] + Q_angle);
      P[0][1] -= dt * P[1][1];
      P[1][0] -= dt * P[1][1];
      P[1][1] += Q_bias * dt;
      float S  = P[0][0] + R_measure;
      float K0 = P[0][0] / S;
      float K1 = P[1][0] / S;
      float y  = newAngle - angle;
      angle   += K0 * y;
      bias    += K1 * y;
      float P00 = P[0][0], P01 = P[0][1];
      P[0][0] -= K0 * P00;
      P[0][1] -= K0 * P01;
      P[1][0] -= K1 * P00;
      P[1][1] -= K1 * P01;
      return angle;
    }
};

KalmanFilter kalmanRoll;
KalmanFilter kalmanPitch;

// ── MPU6050 raw ─────────────────────────────────────────────
const int MPU_ADDR = 0x68;
int16_t rawAccX, rawAccY, rawAccZ;
int16_t rawTemp;
int16_t rawGyroX, rawGyroY, rawGyroZ;

float accX, accY, accZ;
float gyroX, gyroY, gyroZ;
float kalmanAngleX = 0.0f;
float kalmanAngleY = 0.0f;
float gyroAngleZ   = 0.0f;
float temperatureC = 0.0f;
unsigned long mpuTimer = 0;

float gyroBiasX = 0.0f, gyroBiasY = 0.0f, gyroBiasZ = 0.0f;
float accBiasX  = 0.0f, accBiasY  = 0.0f, accBiasZ  = 0.0f;
float svmNoiseFloor = 0.0f;
float svmGyroNoiseFloor = 0.0f;

float svm_acc  = 0.0f;
float svm_gyro = 0.0f;

#define SAMPLE_COUNT 30
float svm_acc_buf[SAMPLE_COUNT]  = {0};
float svm_gyro_buf[SAMPLE_COUNT] = {0};
int   sampleIndex = 0;
float avgSvmAcc   = 0.0f;
float avgSvmGyro  = 0.0f;

#define PANIC_CONFIRM_MS    3000
#define DISTRESS_CONFIRM_MS 8000
unsigned long distressSince = 0;

#define IMMOBILE_THRESHOLD_MS 7200000UL
unsigned long restingSince = 0;
bool immobileAlert = false;

float activityScore = 0.0f;
#define ACTIVITY_SCORE_GAIN  0.5f
#define ACTIVITY_SCORE_DECAY 0.97f
#define ACTIVITY_SCORE_RESET_THRESHOLD 6.0f

String activityLabel = "Resting";

// ============================================================
// GPS + IMU FUSION (Dead Reckoning)
// ============================================================
#define GRAVITY 9.81f

float linAccX = 0.0f, linAccY = 0.0f, linAccZ = 0.0f;
float filtLinAccX = 0.0f, filtLinAccY = 0.0f;
float velX = 0.0f, velY = 0.0f, speed = 0.0f;

double imuOffsetLat = 0.0, imuOffsetLon = 0.0;
double fusedLat = 0.0, fusedLon = 0.0;
double lastGpsLat = 0.0, lastGpsLon = 0.0;

bool isMoving = false;
#define MOTION_THRESHOLD 0.4f
#define VELOCITY_DECAY   0.95f

double currentLat = 0;
double currentLon = 0;
bool gpsFix = false;
unsigned long lastGpsUpdate = 0;
unsigned long lastGpsFixTime = 0;

float fusionWeight = 1.0f;

// ── Fence ───────────────────────────────────────────────────
double fenceLat1 = 0, fenceLon1 = 0;
double fenceLat2 = 0, fenceLon2 = 0;
bool fenceSet = false;
bool buzzerStopped = false;

#define OUTSIDE_CONFIRM_MS 5000
unsigned long outsideSince = 0;
bool wasOutside = false;
bool confirmedOutside = false;

#define BUFFER_METERS 8.0
double metersToDegLat(double m) { return m / 111320.0; }
double metersToDegLon(double m, double lat) {
  return m / (111320.0 * cos(lat * M_PI / 180.0));
}

// ── Fence persistence ───────────────────────────────────────
// Only thing kept on flash — the active fence survives any reboot
// (including the self-healing watchdog below), so protection never
// silently drops even if the ESP has to restart itself.
#define FENCE_FILE "/fence.txt"

void saveFenceToFlash() {
  File f = LittleFS.open(FENCE_FILE, "w");
  if (!f) return;
  f.printf("%.6f,%.6f,%.6f,%.6f\n", fenceLat1, fenceLon1, fenceLat2, fenceLon2);
  f.close();
}

void loadFenceFromFlash() {
  File f = LittleFS.open(FENCE_FILE, "r");
  if (!f) return;
  String line = f.readStringUntil('\n');
  f.close();
  int c1 = line.indexOf(',');
  int c2 = line.indexOf(',', c1 + 1);
  int c3 = line.indexOf(',', c2 + 1);
  if (c1 < 0 || c2 < 0 || c3 < 0) return;
  fenceLat1 = line.substring(0, c1).toDouble();
  fenceLon1 = line.substring(c1 + 1, c2).toDouble();
  fenceLat2 = line.substring(c2 + 1, c3).toDouble();
  fenceLon2 = line.substring(c3 + 1).toDouble();
  fenceSet = true;
  Serial.println("Restored fence from flash after reboot — protection stays active.");
}

void clearFenceFromFlash() {
  LittleFS.remove(FENCE_FILE);
}

// ============================================================
// READ MPU6050
// ============================================================
void readMPUData() {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x3B);
  Wire.endTransmission(false);
  Wire.requestFrom((uint8_t)MPU_ADDR, (size_t)14, true);

  rawAccX  = Wire.read() << 8 | Wire.read();
  rawAccY  = Wire.read() << 8 | Wire.read();
  rawAccZ  = Wire.read() << 8 | Wire.read();
  rawTemp  = Wire.read() << 8 | Wire.read();
  rawGyroX = Wire.read() << 8 | Wire.read();
  rawGyroY = Wire.read() << 8 | Wire.read();
  rawGyroZ = Wire.read() << 8 | Wire.read();

  accX = (float)rawAccX / 16384.0f;
  accY = (float)rawAccY / 16384.0f;
  accZ = (float)rawAccZ / 16384.0f;

  gyroX = (float)rawGyroX / 131.0f - gyroBiasX;
  gyroY = (float)rawGyroY / 131.0f - gyroBiasY;
  gyroZ = (float)rawGyroZ / 131.0f - gyroBiasZ;

  temperatureC = (float)rawTemp / 340.0f + 36.53f;
}

// ============================================================
// UPDATE MPU + IMU FUSION
// ============================================================
void updateMPU() {
  readMPUData();

  float dt = (float)(micros() - mpuTimer) / 1000000.0f;
  if (dt <= 0 || dt > 0.5f) dt = 0.01f;
  mpuTimer = micros();

  float roll  = atan2(accY, accZ) * 180.0f / M_PI;
  float pitch = atan2(-accX, sqrt(accY*accY + accZ*accZ)) * 180.0f / M_PI;

  kalmanAngleX = kalmanRoll.getAngle(roll, gyroX, dt);
  kalmanAngleY = kalmanPitch.getAngle(pitch, gyroY, dt);
  gyroAngleZ  += gyroZ * dt;
  if (gyroAngleZ >  180.0f) gyroAngleZ -= 360.0f;
  if (gyroAngleZ < -180.0f) gyroAngleZ += 360.0f;

  float accX_ms2 = accX * GRAVITY;
  float accY_ms2 = accY * GRAVITY;
  float accZ_ms2 = accZ * GRAVITY;

  float rollRad  = kalmanAngleX * M_PI / 180.0f;
  float pitchRad = kalmanAngleY * M_PI / 180.0f;

  float gravX = -GRAVITY * sin(pitchRad);
  float gravY =  GRAVITY * sin(rollRad) * cos(pitchRad);
  float gravZ =  GRAVITY * cos(rollRad) * cos(pitchRad);

  linAccX = accX_ms2 - gravX - accBiasX;
  linAccY = accY_ms2 - gravY - accBiasY;
  linAccZ = accZ_ms2 - gravZ - accBiasZ;

  #define LPF_ALPHA 0.15f
  filtLinAccX = LPF_ALPHA * linAccX + (1.0f - LPF_ALPHA) * filtLinAccX;
  filtLinAccY = LPF_ALPHA * linAccY + (1.0f - LPF_ALPHA) * filtLinAccY;

  svm_acc  = sqrt(linAccX*linAccX + linAccY*linAccY + linAccZ*linAccZ);
  svm_gyro = sqrt(gyroX*gyroX + gyroY*gyroY + gyroZ*gyroZ);

  float linearMag = sqrt(filtLinAccX*filtLinAccX + filtLinAccY*filtLinAccY);
  isMoving = (linearMag > MOTION_THRESHOLD);

  if (isMoving) {
    velX += filtLinAccX * dt;
    velY += filtLinAccY * dt;
    speed = sqrt(velX*velX + velY*velY);

    if (fusedLat != 0.0) {
      float headingRad = gyroAngleZ * M_PI / 180.0f;
      float globalVelX = velX * cos(headingRad) - velY * sin(headingRad);
      float globalVelY = velX * sin(headingRad) + velY * cos(headingRad);

      double dLon = (globalVelX * dt) / (111320.0 * cos(fusedLat * M_PI / 180.0));
      double dLat = (globalVelY * dt) / 111320.0;
      imuOffsetLat += dLat;
      imuOffsetLon += dLon;

      #define MAX_IMU_DRIFT_M 15.0
      double driftLatM = imuOffsetLat * 111320.0;
      double driftLonM = imuOffsetLon * 111320.0 * cos(fusedLat * M_PI / 180.0);
      double driftDist = sqrt(driftLatM*driftLatM + driftLonM*driftLonM);
      if (driftDist > MAX_IMU_DRIFT_M) {
        double scale = MAX_IMU_DRIFT_M / driftDist;
        imuOffsetLat *= scale;
        imuOffsetLon *= scale;
        velX *= 0.5f;
        velY *= 0.5f;
      }
    }
  } else {
    velX *= VELOCITY_DECAY;
    velY *= VELOCITY_DECAY;
    speed *= VELOCITY_DECAY;

    if (speed < 0.05f) {
      velX = 0; velY = 0; speed = 0;
      imuOffsetLat *= 0.9;
      imuOffsetLon *= 0.9;
    }
  }

  unsigned long gpsAge = millis() - lastGpsFixTime;
  if (lastGpsFixTime == 0 || gpsAge > 10000) {
    fusionWeight = 0.3f;
  } else if (gpsAge > 3000) {
    fusionWeight = 0.6f;
  } else {
    fusionWeight = 0.9f;
  }

  if (fusedLat != 0.0 && fusedLon != 0.0) {
    double imuLat = lastGpsLat + imuOffsetLat;
    double imuLon = lastGpsLon + imuOffsetLon;
    fusedLat = fusionWeight * currentLat + (1.0 - fusionWeight) * imuLat;
    fusedLon = fusionWeight * currentLon + (1.0 - fusionWeight) * imuLon;
  }

  svm_acc_buf[sampleIndex]  = svm_acc;
  svm_gyro_buf[sampleIndex] = svm_gyro;
  sampleIndex = (sampleIndex + 1) % SAMPLE_COUNT;

  avgSvmAcc = 0; avgSvmGyro = 0;
  for (int i = 0; i < SAMPLE_COUNT; i++) {
    avgSvmAcc  += svm_acc_buf[i];
    avgSvmGyro += svm_gyro_buf[i];
  }
  avgSvmAcc  /= SAMPLE_COUNT;
  avgSvmGyro /= SAMPLE_COUNT;

  avgSvmAcc -= svmNoiseFloor;
  if (avgSvmAcc < 0.0f) avgSvmAcc = 0.0f;
  avgSvmGyro -= svmGyroNoiseFloor;
  if (avgSvmGyro < 0.0f) avgSvmGyro = 0.0f;

  if (avgSvmAcc > 5.39f || avgSvmGyro > 50.0f) {
    if (distressSince == 0) distressSince = millis();
    unsigned long heldFor = millis() - distressSince;
    restingSince = 0;

    if (heldFor >= DISTRESS_CONFIRM_MS) {
      activityLabel = "Distress";
    } else if (heldFor >= PANIC_CONFIRM_MS) {
      activityLabel = "Panic";
    }
  } else {
    distressSince = 0;
    if (avgSvmAcc > 4.41f || avgSvmGyro > 27.0f) {
      activityLabel = "Grazing";
      activityScore += ACTIVITY_SCORE_GAIN;
    } else if (avgSvmAcc > 3.43f || avgSvmGyro > 10.0f) {
      activityLabel = "Walking";
      activityScore += ACTIVITY_SCORE_GAIN;
    } else {
      activityScore *= ACTIVITY_SCORE_DECAY;
      if (restingSince == 0) restingSince = millis();
      if (millis() - restingSince >= IMMOBILE_THRESHOLD_MS) {
        activityLabel = "Immobile";
        immobileAlert = true;
      } else {
        activityLabel = "Resting";
      }
    }

    if (activityScore >= ACTIVITY_SCORE_RESET_THRESHOLD) {
      restingSince = 0;
      immobileAlert = false;
      activityScore = 0.0f;
    }
  }
}

// ============================================================
// FENCE + BUZZER
// ============================================================
bool isInsideFence(double lat, double lon) {
  if (!fenceSet) return true;
  double minLat = min(fenceLat1, fenceLat2);
  double maxLat = max(fenceLat1, fenceLat2);
  double minLon = min(fenceLon1, fenceLon2);
  double maxLon = max(fenceLon1, fenceLon2);
  double bufLat = metersToDegLat(BUFFER_METERS);
  double bufLon = metersToDegLon(BUFFER_METERS, lat);
  double iMinLat = minLat + bufLat;
  double iMaxLat = maxLat - bufLat;
  double iMinLon = minLon + bufLon;
  double iMaxLon = maxLon - bufLon;
  if (iMinLat >= iMaxLat || iMinLon >= iMaxLon)
    return (lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon);
  return (lat >= iMinLat && lat <= iMaxLat && lon >= iMinLon && lon <= iMaxLon);
}

bool updateBuzzer(bool insideNow) {
  if (buzzerStopped) { digitalWrite(BUZZER_PIN, LOW); return false; }
  if (!insideNow) {
    if (!wasOutside) {
      outsideSince = millis(); wasOutside = true; confirmedOutside = false;
    } else if (!confirmedOutside && (millis() - outsideSince >= OUTSIDE_CONFIRM_MS)) {
      confirmedOutside = true;
    }
  } else {
    wasOutside = false; confirmedOutside = false; outsideSince = 0;
  }
  bool alert = confirmedOutside;
  digitalWrite(BUZZER_PIN, alert ? HIGH : LOW);
  return alert;
}

// ============================================================
// CORS + connection handling
// ============================================================
void addCORSHeaders() {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  server.sendHeader("Access-Control-Allow-Headers", "Content-Type");
  server.sendHeader("Connection", "close");
}

// ============================================================
// HTTP HANDLERS — only two data endpoints leave the device:
// /gps (location) and /activity (gyro/accel-derived state).
// Both use a fixed char buffer, not String concatenation, so
// these zero-heap-churn even when polled continuously.
// ============================================================
void handleGPS() {
  addCORSHeaders();
  double checkLat = (fusedLat != 0.0) ? fusedLat : currentLat;
  double checkLon = (fusedLon != 0.0) ? fusedLon : currentLon;
  bool alert = confirmedOutside;
  int batteryPct = constrain(map((int)(batteryVoltage * 100), 300, 420, 0, 100), 0, 100);

  char buf[400];
  snprintf(buf, sizeof(buf),
    "{\"lat\":%.6f,\"lon\":%.6f,\"gps_lat\":%.6f,\"gps_lon\":%.6f,"
    "\"fix\":%s,\"battery\":%.2f,\"batteryPct\":%d,\"alert\":%s,"
    "\"fenceSet\":%s,\"speed\":%.2f,\"isMoving\":%s}",
    checkLat, checkLon, currentLat, currentLon,
    gpsFix ? "true" : "false", batteryVoltage, batteryPct, alert ? "true" : "false",
    fenceSet ? "true" : "false", speed, isMoving ? "true" : "false");

  server.send(200, "application/json", buf);
}

void handleActivity() {
  addCORSHeaders();
  char buf[420];
  snprintf(buf, sizeof(buf),
    "{\"activity\":\"%s\",\"svm_acc\":%.3f,\"svm_gyro\":%.2f,"
    "\"roll\":%.2f,\"pitch\":%.2f,\"yaw\":%.2f,\"temp\":%.1f,"
    "\"speed\":%.2f,\"linAccX\":%.3f,\"linAccY\":%.3f,\"linAccZ\":%.3f,"
    "\"isMoving\":%s,\"immobileAlert\":%s}",
    activityLabel.c_str(), avgSvmAcc, avgSvmGyro,
    kalmanAngleX, kalmanAngleY, gyroAngleZ, temperatureC,
    speed, linAccX, linAccY, linAccZ,
    isMoving ? "true" : "false", immobileAlert ? "true" : "false");

  server.send(200, "application/json", buf);
}

void handleSetFence() {
  addCORSHeaders();
  if (!isAuthorised()) {
    server.send(401, "application/json", "{\"status\":\"unauthorised\"}");
    return;
  }
  if (server.hasArg("lat1") && server.hasArg("lon1") &&
      server.hasArg("lat2") && server.hasArg("lon2")) {
    fenceLat1 = server.arg("lat1").toDouble();
    fenceLon1 = server.arg("lon1").toDouble();
    fenceLat2 = server.arg("lat2").toDouble();
    fenceLon2 = server.arg("lon2").toDouble();
    fenceSet = true; buzzerStopped = false;
    wasOutside = false; confirmedOutside = false; outsideSince = 0;
    saveFenceToFlash();
    Serial.println("Fence SET via app.");
    server.send(200, "application/json", "{\"status\":\"fence set\"}");
  } else {
    server.send(400, "application/json", "{\"status\":\"missing params\"}");
  }
}

void handleStop() {
  addCORSHeaders();
  if (!isAuthorised()) {
    server.send(401, "application/json", "{\"status\":\"unauthorised\"}");
    return;
  }
  buzzerStopped = true;
  noTone(BUZZER_PIN);
  server.send(200, "application/json", "{\"status\":\"buzzer stopped\"}");
}

void handleResetFence() {
  addCORSHeaders();
  if (!isAuthorised()) {
    server.send(401, "application/json", "{\"status\":\"unauthorised\"}");
    return;
  }
  fenceSet = false; buzzerStopped = false;
  wasOutside = false; confirmedOutside = false; outsideSince = 0;
  clearFenceFromFlash();
  noTone(BUZZER_PIN);
  server.send(200, "application/json", "{\"status\":\"fence cleared\"}");
}

// ============================================================
// CALIBRATE SENSORS
// ============================================================
void calibrateSensors() {
  Serial.println("Calibrating IMU... keep the collar completely still");

  float sumGX = 0, sumGY = 0, sumGZ = 0;
  const int N1 = 200;
  for (int i = 0; i < N1; i++) {
    readMPUData();
    sumGX += gyroX; sumGY += gyroY; sumGZ += gyroZ;
    delay(5);
  }
  gyroBiasX = sumGX / N1;
  gyroBiasY = sumGY / N1;
  gyroBiasZ = sumGZ / N1;

  for (int i = 0; i < 50; i++) { updateMPU(); delay(5); }

  float sumLX = 0, sumLY = 0, sumLZ = 0;
  const int N2 = 100;
  for (int i = 0; i < N2; i++) {
    updateMPU();
    sumLX += linAccX; sumLY += linAccY; sumLZ += linAccZ;
    delay(5);
  }
  accBiasX = sumLX / N2;
  accBiasY = sumLY / N2;
  accBiasZ = sumLZ / N2;

  float sumSvm = 0, sumSvmGy = 0;
  const int N3 = 100;
  for (int i = 0; i < N3; i++) {
    updateMPU();
    sumSvm += svm_acc;
    sumSvmGy += svm_gyro;
    delay(5);
  }
  svmNoiseFloor = sumSvm / N3;
  svmGyroNoiseFloor = sumSvmGy / N3;

  velX = 0; velY = 0; speed = 0;
  imuOffsetLat = 0; imuOffsetLon = 0;
  filtLinAccX = 0; filtLinAccY = 0;

  Serial.printf("Calibration done. Gyro bias[%.2f,%.2f,%.2f] Acc bias[%.3f,%.3f,%.3f] SVM noise floor=%.3f Gyro SVM noise floor=%.3f\n",
                gyroBiasX, gyroBiasY, gyroBiasZ, accBiasX, accBiasY, accBiasZ, svmNoiseFloor, svmGyroNoiseFloor);
}

// ============================================================
// SETUP
// ============================================================
void setup() {
  Serial.begin(115200);
  gpsSerial.begin(9600);
  pinMode(BUZZER_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, LOW);

  // LittleFS is used ONLY to persist the active fence across reboots
  // now — no history/database buffering at all.
  if (!LittleFS.begin()) {
    Serial.println("LittleFS mount failed — fence will not survive a reboot");
  } else {
    loadFenceFromFlash();
  }

  Wire.begin();

  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x75);
  Wire.endTransmission(false);
  Wire.requestFrom((uint8_t)MPU_ADDR, (size_t)1, true);
  if (Wire.available()) {
    uint8_t whoAmI = Wire.read();
    if (whoAmI == 0x68) {
      Serial.println("MPU6050 detected OK (WHO_AM_I = 0x68)");
    } else {
      Serial.printf("MPU6050 NOT responding correctly! WHO_AM_I = 0x%02X (expected 0x68)\n", whoAmI);
      Serial.println("Check wiring: SDA=D2, SCL=D1, VCC=3.3V, GND, AD0=GND");
    }
  } else {
    Serial.println("MPU6050 NOT FOUND on I2C bus — no response at all.");
    Serial.println("Check wiring: SDA=D2, SCL=D1, VCC=3.3V, GND, AD0=GND, and that the board is soldered/seated properly.");
  }

  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x6B);
  Wire.write(0x00);
  Wire.endTransmission(true);
  delay(100);

  readMPUData();
  kalmanAngleX = atan2(accY, accZ) * 180.0f / M_PI;
  kalmanAngleY = atan2(-accX, sqrt(accY*accY + accZ*accZ)) * 180.0f / M_PI;
  gyroAngleZ   = 0.0f;
  mpuTimer     = micros();

  calibrateSensors();

  WiFi.setSleepMode(WIFI_NONE_SLEEP);
  WiFi.setOutputPower(20.5);
  WiFi.softAP(AP_SSID, AP_PASS, 6, false, 4);
  Serial.println("SmartHerd AP: " + WiFi.softAPIP().toString());

  server.on("/gps",        HTTP_GET,  handleGPS);
  server.on("/activity",   HTTP_GET,  handleActivity);
  server.on("/setfence",   HTTP_POST, handleSetFence);
  server.on("/stop",       HTTP_GET,  handleStop);
  server.on("/resetfence", HTTP_GET,  handleResetFence);
  server.on("/setfence",   HTTP_OPTIONS, []() {
    addCORSHeaders(); server.send(200);
  });

  server.begin();
  Serial.println("SmartHerd Ready!");
}

// ============================================================
// LOOP
// ============================================================
void loop() {
  if (millis() - lastBatterySample >= BATTERY_SAMPLE_INTERVAL_MS) {
    sampleBatteryVoltage();
    lastBatterySample = millis();
  }

  static unsigned long lastSvmDebug = 0;
  if (millis() - lastSvmDebug >= 1000) {
    Serial.printf("avgSvmAcc=%.3f  avgSvmGyro=%.2f  activity=%s  fenceSet=%s  confirmedOutside=%s  APclients=%d  freeHeap=%u\n",
                  avgSvmAcc, avgSvmGyro, activityLabel.c_str(),
                  fenceSet ? "yes" : "no", confirmedOutside ? "yes" : "no",
                  WiFi.softAPgetStationNum(), ESP.getFreeHeap());
    lastSvmDebug = millis();
  }

  // Self-healing low-heap watchdog — see fence persistence note above
  // for why this is safe (fence survives the reboot).
  if (ESP.getFreeHeap() < 8000) {
    Serial.println("Free heap critically low — rebooting to recover cleanly.");
    delay(100);
    ESP.restart();
  }

  while (gpsSerial.available() > 0) gps.encode(gpsSerial.read());

  if (gps.location.isUpdated() && gps.location.isValid()) {
    double newLat = kalmanLat.update(gps.location.lat());
    double newLon = kalmanLon.update(gps.location.lng());
    lastGpsFixTime = millis();

    if (!gpsFix) {
      currentLat   = newLat;
      currentLon   = newLon;
      fusedLat     = newLat;
      fusedLon     = newLon;
      lastGpsLat   = newLat;
      lastGpsLon   = newLon;
      gpsFix       = true;
      Serial.println("GPS Fix acquired!");
    } else {
      double dLat = (newLat - currentLat) * 111320.0;
      double dLon = (newLon - currentLon) * 111320.0 *
                    cos(currentLat * M_PI / 180.0);
      double dist = sqrt(dLat*dLat + dLon*dLon);

      if (dist > 3.0) {
        currentLat = newLat;
        currentLon = newLon;
        lastGpsLat = newLat;
        lastGpsLon = newLon;
        imuOffsetLat = 0.0;
        imuOffsetLon = 0.0;
        lastGpsUpdate = millis();
      }
    }
  }

  static unsigned long lastMPU = 0;
  if (millis() - lastMPU >= 10) {
    updateMPU();
    lastMPU = millis();
  }

  // Fence + buzzer checked continuously on-device, independent of
  // whether a phone is connected/polling at all.
  static unsigned long lastFenceCheck = 0;
  if (millis() - lastFenceCheck >= 200) {
    double checkLat = (fusedLat != 0.0) ? fusedLat : currentLat;
    double checkLon = (fusedLon != 0.0) ? fusedLon : currentLon;
    bool insideFence = true;
    if (gpsFix && fenceSet) insideFence = isInsideFence(checkLat, checkLon);
    updateBuzzer(insideFence);
    lastFenceCheck = millis();
  }

  server.handleClient();
}
