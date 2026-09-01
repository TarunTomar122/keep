#include <Arduino.h>
#include <WebServer.h>
#include <WiFi.h>

constexpr uint8_t BUTTON_PIN = 1; // XIAO D0, button to GND
constexpr uint8_t LED_PIN = 21;    // XIAO built-in yellow LED, active-low

WebServer server(80);
bool previous_button = HIGH;
unsigned long last_press = 0;
unsigned long led_until = 0;

void pulse_led(unsigned long duration) {
  digitalWrite(LED_PIN, LOW);
  led_until = millis() + duration;
}

void handle_status() {
  String body = "KEEP-MONISHA recovery\nmode: hotspot\nip: ";
  body += WiFi.softAPIP().toString();
  body += "\nbutton: D0 to GND\n";
  server.send(200, "text/plain", body);
}

void setup() {
  Serial.begin(115200);
  delay(300);
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, HIGH);

  WiFi.mode(WIFI_AP);
  WiFi.setSleep(false);
  WiFi.softAP("KEEP-MONISHA", "keepmonisha", 1, false, 3);

  server.on("/", handle_status);
  server.on("/status", handle_status);
  server.begin();
  pulse_led(1000);
  Serial.printf("recovery: KEEP-MONISHA at http://%s\n",
                WiFi.softAPIP().toString().c_str());
}

void loop() {
  server.handleClient();

  const bool button = digitalRead(BUTTON_PIN) == LOW;
  if (button && previous_button && millis() - last_press > 250) {
    last_press = millis();
    pulse_led(500);
    Serial.println("recovery: button press on D0");
  }
  previous_button = !button;

  if (led_until != 0 && millis() >= led_until) {
    digitalWrite(LED_PIN, HIGH);
    led_until = 0;
  }
  delay(1);
}
