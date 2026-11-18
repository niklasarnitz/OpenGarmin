# OpenGarmin

A native iOS app that replaces Garmin Connect: pair, set up, sync and train with a Garmin watch, without a Garmin account or cloud. Everything ends up in Apple Health.

First target: **Garmin Venu 4**. The device layer is built so that every Garmin watch supported by Gadgetbridge works.

## Features (milestone 1)

- Onboarding and pairing (Bluetooth bonding, so iOS notifications reach the watch via ANCS)
- Time, profile and settings sync
- FIT download: activities, sleep, heart rate, stress, steps, SpO₂, HRV, respiration → Apple Health
- Activities with route maps and charts
- Workout builder, workouts sent to the watch
- Weather (WeatherKit) and calendar (EventKit) on the watch, GPS assistance data

## Layout

- `App/` – SwiftUI app (XcodeGen spec: `project.yml`, run `xcodegen`)
- `GarminKit/` – Swift package
  - `GarminCore` byte I/O, CRC, COBS
  - `GarminProtocol` GFDI messages
  - `GarminProtobuf` generated from Gadgetbridge's Garmin `.proto` files
  - `GarminTransport` CoreBluetooth, V1 and V2 (multi-link) transport
  - `GarminFIT` FIT decoding/encoding and health data extraction
  - `GarminDevices` catalog of supported devices
  - `GarminSession` the watch session used by the app
  - `GarminHealth` HealthKit writer

## Building

```sh
xcodegen
open OpenGarmin.xcodeproj
cd GarminKit && swift test
```

The reference implementations are not part of this repository. To regenerate code from them, clone them into `vendor/`:

```sh
git clone https://codeberg.org/Freeyourgadget/Gadgetbridge.git vendor/Gadgetbridge
git clone https://github.com/gwerneckp/garmin-ble.git vendor/garmin-ble
```

## Thanks to

- [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) – the Garmin GFDI protocol, FIT handling, protobuf definitions and device list this app is based on.
- [garmin-ble](https://github.com/gwerneckp/garmin-ble) by gwerneckp – a clean Python implementation of the GFDI V2 / MLR stack and realtime metrics.

## License

AGPL-3.0, like the projects it builds on. Not affiliated with Garmin.
