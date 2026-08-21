#include "esp_camera.h"
#include "ESP_I2S.h"
#include <WebServer.h>
#include <WiFi.h>

const char *access_point_name = "CLIPPY-XIAO";
const char *access_point_password = "clippy123";

WebServer server(80);
WiFiServer audio_server(81);
I2SClass microphone;
bool recording = false;

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

  const esp_err_t result = esp_camera_init(&config);
  if (result != ESP_OK) {
    Serial.printf("camera: init failed 0x%lx\n", result);
    while (true) {
      delay(1000);
    }
  }
  Serial.println("camera: initialized at QVGA JPEG");
}

void send_snapshot() {
  camera_fb_t *frame = esp_camera_fb_get();
  if (frame == nullptr) {
    server.send(503, "text/plain", "camera frame unavailable");
    return;
  }

  server.sendHeader("Cache-Control", "no-cache");
  server.setContentLength(frame->len);
  server.send(200, "image/jpeg");
  server.client().write(frame->buf, frame->len);
  esp_camera_fb_return(frame);
}

void stream_video() {
  WiFiClient client = server.client();
  client.println("HTTP/1.1 200 OK");
  client.println("Content-Type: multipart/x-mixed-replace; boundary=frame");
  client.println("Cache-Control: no-cache");
  client.println("Connection: close");
  client.println();

  while (client.connected()) {
    camera_fb_t *frame = esp_camera_fb_get();
    if (frame == nullptr) {
      break;
    }

    client.printf(
        "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n",
        frame->len);
    client.write(frame->buf, frame->len);
    client.print("\r\n");
    esp_camera_fb_return(frame);
    delay(80);
  }
}

void set_recording(bool value) {
  recording = value;
  digitalWrite(LED_BUILTIN, recording ? LOW : HIGH);
  server.send(200, "application/json", recording ? "{\"recording\":true}" : "{\"recording\":false}");
}

void audio_task(void *) {
  uint8_t samples[1024];

  while (true) {
    WiFiClient client = audio_server.available();
    if (!client) {
      vTaskDelay(pdMS_TO_TICKS(5));
      continue;
    }

    client.setNoDelay(true);
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

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, HIGH);
  Serial.begin(115200);
  delay(500);

  configure_camera();

  microphone.setPinsPdmRx(42, 41);
  if (!microphone.begin(I2S_MODE_PDM_RX, 16000, I2S_DATA_BIT_WIDTH_16BIT,
                        I2S_SLOT_MODE_MONO)) {
    Serial.println("audio: PDM microphone init failed");
  } else {
    Serial.println("audio: PDM microphone ready at 16 kHz PCM");
  }

  WiFi.mode(WIFI_AP);
  WiFi.setSleep(false);
  const bool access_point_started = WiFi.softAP(access_point_name, access_point_password, 1, false, 4);
  Serial.printf("wifi: AP start %s, status %d, ip %s\n",
                access_point_started ? "ok" : "failed", WiFi.status(),
                WiFi.softAPIP().toString().c_str());
  Serial.printf("wifi: %s\n", access_point_name);
  Serial.printf("wifi: connect phone to %s, then use http://%s\n", access_point_name, WiFi.softAPIP().toString().c_str());

  server.on("/", HTTP_GET, []() {
    server.send(200, "text/plain", "Clippy XIAO media\n/capture\n/stream\n/audio on port 81\n/status\n/record/start\n/record/stop\n");
  });
  server.on("/capture", HTTP_GET, send_snapshot);
  server.on("/stream", HTTP_GET, stream_video);
  server.on("/status", HTTP_GET, []() {
    server.send(200, "application/json", recording ? "{\"recording\":true,\"audio\":true}" : "{\"recording\":false,\"audio\":true}");
  });
  server.on("/record/start", HTTP_GET, []() { set_recording(true); });
  server.on("/record/stop", HTTP_GET, []() { set_recording(false); });
  server.begin();
  audio_server.begin();
  xTaskCreatePinnedToCore(audio_task, "audio", 8192, nullptr, 1, nullptr, 0);
}

void loop() {
  server.handleClient();
}
