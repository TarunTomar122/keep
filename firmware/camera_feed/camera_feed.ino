#include "esp_camera.h"
#include <WebServer.h>
#include <WiFi.h>

const char *access_point_name = "CLIPPY-XIAO";
const char *access_point_password = "clippy123";

WebServer server(80);

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

void stream_video() {
  WiFiClient client = server.client();
  client.println("HTTP/1.1 200 OK");
  client.println("Content-Type: multipart/x-mixed-replace; boundary=frame");
  client.println("Cache-Control: no-cache");
  client.println("Connection: close");
  client.println();

  while (client.connected()) {
    camera_fb_t *frame = esp_camera_fb_get();
    if (frame == nullptr) break;
    client.printf("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n", frame->len);
    client.write(frame->buf, frame->len);
    client.print("\r\n");
    esp_camera_fb_return(frame);
    delay(100);
  }
}

void setup() {
  Serial.begin(115200);
  delay(500);
  configure_camera();

  WiFi.mode(WIFI_AP);
  WiFi.setSleep(false);
  WiFi.softAP(access_point_name, access_point_password, 1, false, 1);

  server.on("/", HTTP_GET, []() {
    server.send(200, "text/html", R"HTML(
<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Clippy XIAO</title><style>body{margin:0;background:#111;color:#fff;font:18px system-ui;text-align:center}h1{font-size:20px;font-weight:500}img{width:100%;max-width:640px;height:auto}</style>
<h1>Clippy XIAO live feed</h1><img src="/stream">
)HTML");
  });
  server.on("/stream", HTTP_GET, stream_video);
  server.begin();

  Serial.printf("wifi: %s\n", access_point_name);
  Serial.printf("url: http://%s/\n", WiFi.softAPIP().toString().c_str());
}

void loop() {
  server.handleClient();
}
