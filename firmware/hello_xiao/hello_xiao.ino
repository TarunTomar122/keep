const unsigned long heartbeat_interval_ms = 1000;

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, HIGH);
  Serial.begin(115200);
  delay(500);
  Serial.println("clippy: xiao esp32s3 alive");
}

void loop() {
  static unsigned long last_heartbeat = 0;
  const unsigned long now = millis();

  if (now - last_heartbeat < heartbeat_interval_ms) {
    return;
  }

  last_heartbeat = now;
  digitalWrite(LED_BUILTIN, !digitalRead(LED_BUILTIN));
  Serial.printf("clippy: heartbeat %lu ms\n", now);
}
