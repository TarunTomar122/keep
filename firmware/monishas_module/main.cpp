#include <Arduino.h>
#include <ESPmDNS.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <WebServer.h>
#include <WiFi.h>
#include <driver/rtc_io.h>
#include <esp_sleep.h>
#include <time.h>

#include "EPD_3in6e.h"

#ifndef KEEP_SERVER_URL
#define KEEP_SERVER_URL ""
#endif

#ifndef KEEP_SERVER_TOKEN
#define KEEP_SERVER_TOKEN ""
#endif

constexpr size_t FRAME_BYTES = 120000;
constexpr uint8_t BUTTON_PIN = 1;    // XIAO D0, button to GND
constexpr uint8_t USER_LED_PIN = 21; // Built-in yellow LED, active-low
constexpr unsigned long BUTTON_HOLD_MS = 3000;
constexpr unsigned long AWAKE_WINDOW_MS = 2UL * 60UL * 1000UL;
constexpr unsigned long DEMO_INTERVAL_MS = 20UL * 1000UL;
constexpr uint32_t DAY_SECONDS = 24UL * 60UL * 60UL;
constexpr uint32_t RETRY_SLEEP_SECONDS = 5UL * 60UL;
constexpr time_t VALID_EPOCH = 1700000000;
constexpr uint8_t DEMO_COUNT = 6;

const char *AP_NAME = "KEEP-MONISHA";
const char *AP_PASSWORD = "keepmonisha";

WebServer server(80);
Preferences preferences;

enum class LedState { hotspot, connecting, connected, fetching, error };
enum class FetchResult { updated, unchanged, failed };

LedState led_state = LedState::hotspot;
unsigned long led_started_at = 0;
bool station_mode = false;
bool server_started = false;
bool fetch_pending = false;
bool force_fetch_pending = false;
bool demo_mode = false;
bool button_was_down = false;
bool button_hold_handled = false;
unsigned long button_down_at = 0;
unsigned long awake_until = 0;
unsigned long restart_at = 0;
unsigned long next_demo_at = 0;
uint32_t wake_epoch = 0;
uint8_t demo_index = 0;
String last_moment;
uint8_t *frame = nullptr;

void set_led(LedState state) {
  led_state = state;
  led_started_at = millis();
}

void update_led() {
  const unsigned long elapsed = millis() - led_started_at;
  const unsigned long phase = elapsed % 1800;
  bool on = false;

  switch (led_state) {
    case LedState::hotspot:
      on = phase < 500;
      break;
    case LedState::connecting:
      on = (elapsed % 240) < 80;
      break;
    case LedState::connected:
      on = phase < 120 || (phase >= 300 && phase < 420);
      break;
    case LedState::fetching:
      on = true;
      break;
    case LedState::error:
      on = phase < 80 || (phase >= 220 && phase < 300) ||
           (phase >= 440 && phase < 520);
      break;
  }

  digitalWrite(USER_LED_PIN, on ? LOW : HIGH);
}

void signal_button_wake() {
  for (uint8_t i = 0; i < 3; ++i) {
    digitalWrite(USER_LED_PIN, LOW);
    delay(90);
    digitalWrite(USER_LED_PIN, HIGH);
    delay(90);
  }
}

void clear_wifi_credentials() {
  preferences.remove("ssid");
  preferences.remove("password");
  Serial.println("button: Wi-Fi credentials cleared");
}

void schedule_restart() {
  restart_at = millis() + 1000;
}

bool sync_clock() {
  setenv("TZ", "IST-5:30", 1);
  tzset();
  configTime(0, 0, "pool.ntp.org", "time.nist.gov");

  const unsigned long deadline = millis() + 10000;
  while (time(nullptr) < VALID_EPOCH && millis() < deadline) {
    update_led();
    delay(100);
  }
  const bool ready = time(nullptr) >= VALID_EPOCH;
  Serial.println(ready ? "clock: synchronized" : "clock: sync failed");
  return ready;
}

uint32_t next_six_am() {
  const time_t now = time(nullptr);
  struct tm local_now;
  localtime_r(&now, &local_now);
  local_now.tm_hour = 6;
  local_now.tm_min = 0;
  local_now.tm_sec = 0;
  time_t target = mktime(&local_now);
  if (target <= now) {
    local_now.tm_mday++;
    target = mktime(&local_now);
  }
  return static_cast<uint32_t>(target);
}

void enter_deep_sleep(uint32_t override_seconds = 0) {
  if (digitalRead(BUTTON_PIN) == LOW) return;

  uint32_t sleep_seconds = override_seconds;
  const time_t now = time(nullptr);
  if (sleep_seconds == 0 && now >= VALID_EPOCH && wake_epoch >= VALID_EPOCH) {
    while (wake_epoch <= static_cast<uint32_t>(now)) wake_epoch += DAY_SECONDS;
    preferences.putUInt("wake_epoch", wake_epoch);
    sleep_seconds = wake_epoch - static_cast<uint32_t>(now);
  }
  if (sleep_seconds == 0) sleep_seconds = RETRY_SLEEP_SECONDS;

  digitalWrite(USER_LED_PIN, HIGH);
  rtc_gpio_init(GPIO_NUM_1);
  rtc_gpio_set_direction(GPIO_NUM_1, RTC_GPIO_MODE_INPUT_ONLY);
  rtc_gpio_pullup_en(GPIO_NUM_1);
  rtc_gpio_pulldown_dis(GPIO_NUM_1);
  esp_sleep_enable_ext0_wakeup(GPIO_NUM_1, 0);
  esp_sleep_enable_timer_wakeup(
      static_cast<uint64_t>(sleep_seconds) * 1000000ULL);
  Serial.printf("sleep: %lu seconds\n", static_cast<unsigned long>(sleep_seconds));
  Serial.flush();
  delay(100);
  esp_deep_sleep_start();
}

void start_access_point() {
  station_mode = false;
  set_led(LedState::hotspot);
  WiFi.mode(WIFI_AP);
  WiFi.setSleep(false);
  if (!WiFi.softAP(AP_NAME, AP_PASSWORD, 1, false, 3)) {
    set_led(LedState::error);
    Serial.println("wifi: hotspot failed");
    return;
  }
  Serial.printf("wifi: %s at http://%s\n", AP_NAME,
                WiFi.softAPIP().toString().c_str());
}

bool connect_saved_wifi() {
  const String ssid = preferences.getString("ssid", "");
  if (ssid.isEmpty()) return false;
  const String password = preferences.getString("password", "");

  set_led(LedState::connecting);
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.begin(ssid.c_str(), password.c_str());

  const unsigned long deadline = millis() + 20000;
  while (WiFi.status() != WL_CONNECTED && millis() < deadline) {
    update_led();
    delay(100);
  }
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("wifi: saved network unavailable");
    return false;
  }

  station_mode = true;
  set_led(LedState::connected);
  if (MDNS.begin("monisha")) MDNS.addService("clippy", "tcp", 80);
  Serial.printf("wifi: connected at http://%s\n",
                WiFi.localIP().toString().c_str());
  return true;
}

bool ensure_frame_buffer() {
  if (frame != nullptr) return true;
  if (psramFound()) frame = static_cast<uint8_t *>(ps_malloc(FRAME_BYTES));
  if (frame == nullptr) frame = static_cast<uint8_t *>(malloc(FRAME_BYTES));
  if (frame == nullptr) Serial.println("latest: frame allocation failed");
  return frame != nullptr;
}

String normalized_moment(String value) {
  value.trim();
  if (value.startsWith("\"") && value.endsWith("\"")) {
    value = value.substring(1, value.length() - 1);
  }
  return value;
}

void display_frame() {
  DEV_Module_Init();
  EPD_3IN6E_Init();
  EPD_3IN6E_Display(frame);
  EPD_3IN6E_Sleep();
  DEV_Module_Exit();
}

FetchResult fetch_latest(bool force) {
  if (!station_mode || WiFi.status() != WL_CONNECTED || !ensure_frame_buffer()) {
    return FetchResult::failed;
  }
  if (String(KEEP_SERVER_URL).isEmpty() || String(KEEP_SERVER_TOKEN).isEmpty()) {
    Serial.println("latest: built-in server configuration missing");
    return FetchResult::failed;
  }

  String url = KEEP_SERVER_URL;
  if (url.endsWith("/")) url.remove(url.length() - 1);
  if (demo_mode) {
    url += "/demo/frame/";
    url += String(demo_index);
  } else {
    url += "/latest";
  }

  static WiFiClient client;
  client.stop();
  HTTPClient http;
  if (!http.begin(client, url)) {
    Serial.println("latest: could not open URL");
    return FetchResult::failed;
  }

  const char *headers[] = {"X-Moment-Id", "ETag"};
  http.collectHeaders(headers, 2);
  http.useHTTP10(true);
  http.setReuse(false);
  http.setConnectTimeout(10000);
  http.setTimeout(25000);
  http.addHeader("Authorization", "Bearer " + String(KEEP_SERVER_TOKEN));
  if (!force && !demo_mode && !last_moment.isEmpty()) {
    http.addHeader("If-None-Match", "\"" + last_moment + "\"");
  }

  Serial.printf("latest: fetching %s\n", url.c_str());
  const int status = http.GET();
  if (status == HTTP_CODE_NOT_MODIFIED) {
    http.end();
    client.stop();
    Serial.println("latest: unchanged");
    return FetchResult::unchanged;
  }
  if (status != HTTP_CODE_OK) {
    Serial.printf("latest: HTTP %d\n", status);
    http.end();
    client.stop();
    return FetchResult::failed;
  }

  const int content_length = http.getSize();
  if (content_length > 0 && content_length != FRAME_BYTES) {
    Serial.printf("latest: unexpected size %d\n", content_length);
    http.end();
    client.stop();
    return FetchResult::failed;
  }

  NetworkClient *stream = http.getStreamPtr();
  size_t received = 0;
  const unsigned long deadline = millis() + 30000;
  while (received < FRAME_BYTES && millis() < deadline) {
    const size_t available = stream->available();
    if (available > 0) {
      const size_t wanted = min(available, FRAME_BYTES - received);
      received += stream->readBytes(
          reinterpret_cast<char *>(frame + received), wanted);
      continue;
    }
    if (!stream->connected()) break;
    delay(2);
  }

  const String moment = normalized_moment(
      http.header("X-Moment-Id").isEmpty() ? http.header("ETag")
                                           : http.header("X-Moment-Id"));
  http.end();
  client.stop();
  delay(50);

  if (received != FRAME_BYTES) {
    Serial.printf("latest: received %u of %u bytes\n",
                  static_cast<unsigned>(received),
                  static_cast<unsigned>(FRAME_BYTES));
    return FetchResult::failed;
  }

  display_frame();
  if (demo_mode) {
    demo_index = (demo_index + 1) % DEMO_COUNT;
    preferences.putUChar("demo_index", demo_index);
  } else if (!moment.isEmpty()) {
    last_moment = moment;
    preferences.putString("last_moment", last_moment);
  }
  Serial.println("latest: displayed");
  return FetchResult::updated;
}

FetchResult run_fetch(const char *reason, bool force) {
  Serial.printf("latest: %s refresh\n", reason);
  set_led(LedState::fetching);
  const FetchResult result = fetch_latest(force);
  set_led(result == FetchResult::failed ? LedState::error
                                        : LedState::connected);
  return result;
}

void send_status() {
  String payload = "{\"role\":\"monisha\",\"configured\":";
  payload += preferences.getString("ssid", "").isEmpty() ? "false" : "true";
  payload += ",\"connected\":";
  payload += WiFi.status() == WL_CONNECTED ? "true" : "false";
  payload += ",\"mode\":\"";
  payload += station_mode ? "station" : "ap";
  payload += "\",\"ip\":\"";
  payload += station_mode ? WiFi.localIP().toString() : WiFi.softAPIP().toString();
  payload += "\",\"server_configured\":true,\"wake_epoch\":";
  payload += wake_epoch;
  payload += ",\"demo_mode\":";
  payload += demo_mode ? "true" : "false";
  payload += ",\"last_moment\":\"";
  payload += last_moment;
  payload += "\"}";
  server.send(200, "application/json", payload);
}

void save_wifi() {
  const String ssid = server.arg("ssid");
  if (ssid.isEmpty()) {
    server.send(400, "application/json",
                "{\"saved\":false,\"error\":\"ssid required\"}");
    return;
  }
  preferences.putString("ssid", ssid);
  preferences.putString("password", server.arg("password"));
  server.send(200, "application/json",
              "{\"saved\":true,\"restarting\":true}");
  schedule_restart();
}

void save_schedule() {
  const uint32_t requested = strtoul(server.arg("wake_epoch").c_str(), nullptr, 10);
  if (requested < VALID_EPOCH) {
    server.send(400, "application/json",
                "{\"saved\":false,\"error\":\"invalid wake_epoch\"}");
    return;
  }
  wake_epoch = requested;
  preferences.putUInt("wake_epoch", wake_epoch);
  awake_until = millis() + AWAKE_WINDOW_MS;
  String payload = "{\"saved\":true,\"wake_epoch\":";
  payload += wake_epoch;
  payload += "}";
  server.send(200, "application/json", payload);
}

void queue_refresh() {
  if (!station_mode) {
    server.send(409, "application/json",
                "{\"queued\":false,\"error\":\"board is in hotspot mode\"}");
    return;
  }
  fetch_pending = true;
  force_fetch_pending = true;
  awake_until = millis() + AWAKE_WINDOW_MS;
  server.send(202, "application/json", "{\"queued\":true}");
}

void start_demo() {
  if (!station_mode) {
    server.send(409, "application/json", "{\"running\":false}");
    return;
  }
  demo_mode = true;
  demo_index = 0;
  fetch_pending = true;
  force_fetch_pending = true;
  next_demo_at = 0;
  server.send(200, "application/json", "{\"running\":true}");
}

void stop_demo() {
  demo_mode = false;
  awake_until = millis() + AWAKE_WINDOW_MS;
  server.send(200, "application/json", "{\"running\":false}");
}

void reset_wifi() {
  clear_wifi_credentials();
  server.send(200, "application/json",
              "{\"reset\":true,\"restarting\":true}");
  schedule_restart();
}

void start_server() {
  if (server_started) return;
  server.on("/", HTTP_GET, []() {
    server.send(200, "text/plain",
                "Keep Monisha\n/status\n/refresh\n/wifi/config\n/schedule\n/demo/start\n/demo/stop\n/wifi/reset\n");
  });
  server.on("/status", HTTP_GET, send_status);
  server.on("/wifi/config", HTTP_POST, save_wifi);
  server.on("/schedule", HTTP_POST, save_schedule);
  server.on("/refresh", HTTP_GET, queue_refresh);
  server.on("/demo/start", HTTP_POST, start_demo);
  server.on("/demo/stop", HTTP_POST, stop_demo);
  server.on("/wifi/reset", HTTP_POST, reset_wifi);
  server.begin();
  server_started = true;
}

void handle_button() {
  const bool down = digitalRead(BUTTON_PIN) == LOW;
  if (down && !button_was_down) {
    button_down_at = millis();
    button_hold_handled = false;
  }

  if (down && !button_hold_handled &&
      millis() - button_down_at >= BUTTON_HOLD_MS) {
    button_hold_handled = true;
    clear_wifi_credentials();
    set_led(LedState::fetching);
    schedule_restart();
  }

  if (!down && button_was_down && !button_hold_handled &&
      millis() - button_down_at >= 50) {
    signal_button_wake();
    if (station_mode) {
      fetch_pending = true;
      force_fetch_pending = true;
      awake_until = millis() + AWAKE_WINDOW_MS;
    }
  }
  button_was_down = down;
}

bool handle_button_wakeup() {
  if (esp_sleep_get_wakeup_cause() != ESP_SLEEP_WAKEUP_EXT0) return false;

  const unsigned long pressed_at = millis();
  while (digitalRead(BUTTON_PIN) == LOW &&
         millis() - pressed_at < BUTTON_HOLD_MS) {
    delay(10);
  }
  if (digitalRead(BUTTON_PIN) == LOW) {
    clear_wifi_credentials();
    digitalWrite(USER_LED_PIN, LOW);
    delay(300);
    ESP.restart();
  }
  signal_button_wake();
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(500);
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  pinMode(USER_LED_PIN, OUTPUT);
  digitalWrite(USER_LED_PIN, HIGH);
  preferences.begin("monisha", false);
  wake_epoch = preferences.getUInt("wake_epoch", 0);
  demo_index = preferences.getUChar("demo_index", 0) % DEMO_COUNT;
  last_moment = preferences.getString("last_moment", "");

  const bool woke_by_button = handle_button_wakeup();
  if (!connect_saved_wifi()) {
    start_access_point();
    start_server();
    return;
  }

  if (sync_clock() && wake_epoch == 0) {
    wake_epoch = next_six_am();
    preferences.putUInt("wake_epoch", wake_epoch);
    Serial.println("schedule: default 06:00 IST configured");
  }

  const FetchResult result = run_fetch(
      woke_by_button ? "button wake" : "boot", woke_by_button);
  if (woke_by_button) {
    start_server();
    awake_until = millis() + AWAKE_WINDOW_MS;
    return;
  }
  enter_deep_sleep(result == FetchResult::failed ? RETRY_SLEEP_SECONDS : 0);
}

void loop() {
  update_led();
  handle_button();
  if (server_started) server.handleClient();

  if (restart_at != 0 && millis() >= restart_at) ESP.restart();

  if (fetch_pending) {
    const bool force = force_fetch_pending;
    fetch_pending = false;
    force_fetch_pending = false;
    run_fetch(demo_mode ? "demo" : "manual", force);
    if (demo_mode) next_demo_at = millis() + DEMO_INTERVAL_MS;
  }

  if (demo_mode && next_demo_at != 0 && millis() >= next_demo_at) {
    fetch_pending = true;
    force_fetch_pending = true;
    next_demo_at = 0;
  }

  if (station_mode && !demo_mode && awake_until != 0 &&
      millis() >= awake_until) {
    enter_deep_sleep();
  }
  delay(1);
}
