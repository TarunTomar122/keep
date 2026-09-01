#include <Arduino.h>

constexpr uint8_t SENSE = 1; // XIAO D0

void driveTestPinsHigh() {
  for (uint8_t pin : {7, 8, 9, 3, 2, 5}) {
    pinMode(pin, OUTPUT);
    digitalWrite(pin, HIGH);
  }
}

void setup() {
  pinMode(SENSE, INPUT_PULLDOWN);
  pinMode(LED_BUILTIN, OUTPUT);
  driveTestPinsHigh();
}

void loop() {
  const bool connected = digitalRead(SENSE);
  // XIAO's built-in LED is active-low. Blink only while D0 reads 3.3 V.
  digitalWrite(LED_BUILTIN, connected && (millis() / 200) % 2 ? LOW : HIGH);
}
