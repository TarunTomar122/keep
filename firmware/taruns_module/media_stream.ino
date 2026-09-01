#include "ESP_I2S.h"
#include "esp_camera.h"
#include <WebServer.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <ESPmDNS.h>
#include <Preferences.h>

const char *access_point_name = "CLIPPY-XIAO";
const char *access_point_password = "clippy123";

WebServer control_server(80);
WiFiServer audio_server(81);
WiFiServer video_server(82);
WiFiUDP discovery_server;
I2SClass microphone;
Preferences wifi_preferences;
bool recording = false;
bool station_mode = false;
unsigned long restart_at = 0;
const uint16_t discovery_port = 4210;

void start_access_point() {
  WiFi.mode(WIFI_AP);
  WiFi.setSleep(false);
  station_mode = false;
  if (!WiFi.softAP(access_point_name, access_point_password, 1, false, 3)) {
    Serial.println("wifi: AP start failed");
    return;
  }
  Serial.printf("wifi: AP %s at %s\n", access_point_name,
                WiFi.softAPIP().toString().c_str());
}
bool connect_saved_wifi() {
  const String ssid = wifi_preferences.getString("ssid", "");
  const String password = wifi_preferences.getString("password", "");
  if (ssid.isEmpty()) return false;

  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.begin(ssid.c_str(), password.c_str());
  Serial.printf("wifi: connecting to %s", ssid.c_str());

  const unsigned long deadline = millis() + 15000;
  while (WiFi.status() != WL_CONNECTED && millis() < deadline) {
    delay(250);
    Serial.print('.');
  }
  Serial.println();

  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("wifi: saved network unavailable; falling back to AP");
    WiFi.disconnect(true);
    return false;
  }

  station_mode = true;
  if (MDNS.begin("clippy")) {
    MDNS.addService("clippy", "tcp", 80);
  }
  Serial.printf("wifi: connected at http://%s\n",
                WiFi.localIP().toString().c_str());
  return true;
}

void schedule_restart() {
  restart_at = millis() + 1000;
}

void send_status() {
  const bool configured = !wifi_preferences.getString("ssid", "").isEmpty();
  const bool connected = WiFi.status() == WL_CONNECTED;
  const String ip = station_mode ? WiFi.localIP().toString()
                                 : WiFi.softAPIP().toString();
  String payload = "{";
  payload += "\"configured\":";
  payload += configured ? "true" : "false";
  payload += ",\"connected\":";
  payload += connected ? "true" : "false";
  payload += ",\"mode\":\"";
  payload += station_mode ? "station" : "ap";
  payload += "\",\"ip\":\"";
  payload += ip;
  payload += "\",\"recording\":";
  payload += recording ? "true" : "false";
  payload += ",\"audio\":true,\"video\":true}";
  control_server.send(200, "application/json", payload);
}

void save_wifi() {
  if (!control_server.hasArg("ssid")) {
    control_server.send(400, "application/json", "{\"saved\":false,\"error\":\"ssid required\"}");
    return;
  }

  const String ssid = control_server.arg("ssid");
  const String password = control_server.arg("password");
  if (ssid.isEmpty()) {
    control_server.send(400, "application/json", "{\"saved\":false,\"error\":\"ssid required\"}");
    return;
  }

  wifi_preferences.putString("ssid", ssid);
  wifi_preferences.putString("password", password);
  control_server.send(200, "application/json", "{\"saved\":true,\"restarting\":true}");
  schedule_restart();
}

void reset_wifi() {
  wifi_preferences.clear();
  control_server.send(200, "application/json", "{\"reset\":true,\"restarting\":true}");
  schedule_restart();
}

void handle_discovery() {
  const int packet_size = discovery_server.parsePacket();
  if (packet_size <= 0) return;

  char message[32];
  const size_t length = discovery_server.read(message, sizeof(message) - 1);
  message[length] = '\0';
  if (String(message) != "CLIPPY_DISCOVER") return;

  discovery_server.beginPacket(discovery_server.remoteIP(),
                               discovery_server.remotePort());
  discovery_server.print("CLIPPY_XIAO");
  discovery_server.endPacket();
}

void configure_camera() {
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = 15;
  config.pin_d1 = 17;
  config.pin_d2 = 18;
  config.pin_d3 = 16;
  config.pin_d4 = 14;
  config.pin_d5 = 12;
  config.pin_d6 = 11;
  config.pin_d7 = 48;
  config.pin_xclk = 10;
  config.pin_pclk = 13;
  config.pin_vsync = 38;
  config.pin_href = 47;
  config.pin_sccb_sda = 40;
  config.pin_sccb_scl = 39;
  config.pin_pwdn = -1;
  config.pin_reset = -1;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size = FRAMESIZE_QVGA;
  config.jpeg_quality = 12;
  config.fb_count = psramFound() ? 2 : 1;
  config.grab_mode = CAMERA_GRAB_LATEST;
  config.fb_location = psramFound() ? CAMERA_FB_IN_PSRAM : CAMERA_FB_IN_DRAM;

  if (esp_camera_init(&config) != ESP_OK) {
    Serial.println("camera: init failed");
    while (true) delay(1000);
  }
  Serial.println("camera: ready");
}

bool consume_request(WiFiClient &client) {
  client.setTimeout(1000);
  if (client.readStringUntil('\n').length() == 0) return false;
  while (client.connected()) {
    const String header = client.readStringUntil('\n');
    if (header == "\r" || header.length() == 0) break;
  }
  return true;
}

void video_task(void *) {
  while (true) {
    WiFiClient client = video_server.available();
    if (!client) {
      vTaskDelay(pdMS_TO_TICKS(5));
      continue;
    }
    if (!consume_request(client)) {
      client.stop();
      continue;
    }

    client.println("HTTP/1.1 200 OK");
    client.println("Content-Type: multipart/x-mixed-replace; boundary=frame");
    client.println("Cache-Control: no-cache");
    client.println("Connection: close");
    client.println();

    while (client.connected()) {
      camera_fb_t *frame = esp_camera_fb_get();
      if (frame == nullptr) break;
      const size_t frame_len = frame->len;
      client.printf("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n", frame_len);
      const size_t written = client.write(frame->buf, frame_len);
      client.print("\r\n");
      esp_camera_fb_return(frame);
      if (written != frame_len) break;
      vTaskDelay(pdMS_TO_TICKS(80));
    }
    client.stop();
  }
}

void audio_task(void *) {
  uint8_t samples[1024];
  while (true) {
    WiFiClient client = audio_server.available();
    if (!client) {
      vTaskDelay(pdMS_TO_TICKS(5));
      continue;
    }
    if (!consume_request(client)) {
      client.stop();
      continue;
    }

    client.println("HTTP/1.1 200 OK");
    client.println("Content-Type: audio/pcm; rate=16000; channels=1; format=s16le");
    client.println("Cache-Control: no-cache");
    client.println("Connection: close");
    client.println();

    while (client.connected()) {
      const size_t bytes_read = microphone.readBytes((char *)samples, sizeof(samples));
      if (bytes_read == 0 || client.write(samples, bytes_read) != bytes_read) break;
    }
    client.stop();
  }
}

void send_snapshot() {
  camera_fb_t *frame = esp_camera_fb_get();
  if (frame == nullptr) {
    control_server.send(503, "text/plain", "camera frame unavailable");
    return;
  }

  control_server.sendHeader("Cache-Control", "no-cache");
  control_server.sendHeader("Connection", "close");
  control_server.setContentLength(frame->len);
  control_server.send(200, "image/jpeg");
  WiFiClient client = control_server.client();
  size_t sent = 0;
  while (sent < frame->len) {
    const size_t written = client.write(frame->buf + sent, frame->len - sent);
    if (written == 0) break;
    sent += written;
  }
  client.flush();
  esp_camera_fb_return(frame);
  client.stop();
}

void set_recording(bool value) {
  recording = value;
  digitalWrite(LED_BUILTIN, recording ? LOW : HIGH);
  control_server.send(200, "application/json", recording ? "{\"recording\":true}" : "{\"recording\":false}");
}

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, HIGH);
  Serial.begin(115200);
  delay(500);
  wifi_preferences.begin("wifi", false);
  configure_camera();

  microphone.setPinsPdmRx(42, 41);
  if (!microphone.begin(I2S_MODE_PDM_RX, 16000, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO)) {
    Serial.println("audio: init failed");
  } else {
    Serial.println("audio: ready at 16 kHz PCM");
  }

  if (!connect_saved_wifi()) start_access_point();
  discovery_server.begin(discovery_port);

  control_server.on("/", HTTP_GET, []() {
    control_server.send(200, "text/plain", "Clippy media\ncapture: /capture\nvideo: /stream on port 82\naudio: /audio on port 81\nstatus: /status\nwifi: POST /wifi/config\nreset: POST /wifi/reset\n");
  });
  control_server.on("/capture", HTTP_GET, send_snapshot);
  control_server.on("/status", HTTP_GET, send_status);
  control_server.on("/wifi/config", HTTP_POST, save_wifi);
  control_server.on("/wifi/reset", HTTP_POST, reset_wifi);
  control_server.on("/record/start", HTTP_GET, []() { set_recording(true); });
  control_server.on("/record/stop", HTTP_GET, []() { set_recording(false); });
  control_server.begin();
  audio_server.begin();
  video_server.begin();
  xTaskCreatePinnedToCore(audio_task, "audio", 8192, nullptr, 1, nullptr, 0);
  xTaskCreatePinnedToCore(video_task, "video", 8192, nullptr, 1, nullptr, 0);

  Serial.printf("wifi: %s\n", access_point_name);
  Serial.printf("status: http://%s/status\n", WiFi.softAPIP().toString().c_str());
  Serial.printf("video: http://%s:82/stream\n", WiFi.softAPIP().toString().c_str());
  Serial.printf("audio: http://%s:81/audio\n", WiFi.softAPIP().toString().c_str());
}

void loop() {
  control_server.handleClient();
  handle_discovery();
  if (restart_at != 0 && millis() >= restart_at) ESP.restart();
}
