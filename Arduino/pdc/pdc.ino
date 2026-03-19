#include <SPI.h>
#include <mcp2515.h>

#define SLAVE_ID 0x0F6
#define PIN_OUT 3              // 속도 센서 핀
#define TRIG 8                 // 초음파 Trig
#define ECHO 7                 // 초음파 Echo
#define CUSTOM_DELAY 100       // 측정 주기 [ms]
#define WHEEL_CIRCUMFERENCE_CM 20.083  
#define PULSES_PER_REV 20      

MCP2515 mcp2515(9);
volatile unsigned int pulseCount = 0;
struct can_frame canMsg;

/* 거리 데이터를 위한 Union (4바이트 float) */
union DistanceUnion {
    float value;
    byte bytes[4];
} distanceData;

// 속도 센서 인터럽트 함수
void isrCount() {
    pulseCount++;
}

// 초음파 거리 측정 함수
float getDistance() {
    digitalWrite(TRIG, LOW);
    delayMicroseconds(2);
    digitalWrite(TRIG, HIGH);
    delayMicroseconds(10);
    digitalWrite(TRIG, LOW);
    
    // 타임아웃 50ms (약 8.5m 거리까지 측정 가능)
    float cycletime = pulseIn(ECHO, HIGH, 50000); 
    
    if (cycletime == 0) return -1.0; // 측정 실패 시
    
    // 시간(us)을 cm로 변환: (시간 * 음속(340m/s)) / 10000 / 왕복(2)
    return ((340.0 * cycletime) / 10000.0) / 2.0;
}

void setup() {
    Serial.begin(115200);

    // CAN 초기화 (1000KBPS)
    mcp2515.reset();
    mcp2515.setBitrate(CAN_1000KBPS, MCP_16MHZ);
    mcp2515.setNormalMode();

    // 속도 센서 설정
    pinMode(PIN_OUT, INPUT);
    attachInterrupt(digitalPinToInterrupt(PIN_OUT), isrCount, RISING);

    // 초음파 센서 설정
    pinMode(TRIG, OUTPUT);
    pinMode(ECHO, INPUT);

    // CAN 메시지 기본 틀 설정
    canMsg.can_id = SLAVE_ID;
    canMsg.can_dlc = 8;
    memset(canMsg.data, 0x00, 8);
}

void loop() {
    // 1. 측정 주기 대기
    delay(CUSTOM_DELAY);

    // 2. 속도 계산 (인터럽트 안전하게 복사)
    noInterrupts();
    unsigned int pulses = pulseCount;
    pulseCount = 0;
    interrupts();

    float intervalSec = CUSTOM_DELAY / 1000.0;
    float revs = pulses / (float)PULSES_PER_REV;
    float speed = revs * WHEEL_CIRCUMFERENCE_CM / intervalSec;

    // 3. 거리 측정
    distanceData.value = getDistance();

    // 4. CAN 데이터 패킹 (데이터 구성)
    // [속도 데이터 - 0, 1, 2번 인덱스]
    int int1_spd = (int)speed;
    int int2_spd = round((speed - int1_spd) * 100);

    canMsg.data[0] = int1_spd / 256;      // 정수 상위 바이트
    canMsg.data[1] = int1_spd % 256;      // 정수 하위 바이트
    canMsg.data[2] = (byte)int2_spd;      // 소수점 2자리

    // [거리 데이터 - 3, 4, 5, 6번 인덱스] (Float 4바이트)
    for (int i = 0; i < 4; i++) {
        canMsg.data[3 + i] = distanceData.bytes[i];
    }

    canMsg.data[7] = 0x00; // 마지막 바이트 비움

    // 5. 시리얼 출력 (항상) + CAN 메시지 전송 (가능한 경우)
    Serial.print("Speed: "); Serial.print(speed);
    Serial.print(" cm/s, Distance: "); Serial.print(distanceData.value);
    Serial.println(" cm [Sent]");

    mcp2515.sendMessage(&canMsg);  // Best-effort CAN send (no CAN hat = silently fails)
}