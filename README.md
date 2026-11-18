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

## Server (self-hosted backend)

`Server/` is a Swift (Vapor) server with PostgreSQL. It keeps every raw FIT file, Garmin Connect response and Apple Health
sample forever, at full resolution, and serves the API in `docs/backend-api.md` and the dashboard in `Web/`. The
dashboard is built into the image; `Server/Public/` holds only the placeholder and `connect.html`.

### Run with Docker Compose

```sh
cd Server
cp docker-compose.example.yml docker-compose.yml   # change every "change-me"
docker compose up -d
```

The first account is registered with `POST /api/v1/auth/register` (the app's sign-up does this too). Later
accounts need `OPENGARMIN_ALLOW_SIGNUP=true`. Put the server behind HTTPS (a reverse proxy) before you expose it, because
the session cookie is `Secure`. The compose file's `s3` service stores raw bytes in S3; create the bucket once (see the
comment in the file). Without S3, remove the five `OPENGARMIN_S3_*` lines and the `s3` service, and the server keeps the
files in `/data`.

To build the image yourself, use the repository root as build context:

```sh
docker build -f Server/Dockerfile -t opengarmin-server .
```

### Environment

| Variable | Meaning |
| --- | --- |
| `DATABASE_URL` | PostgreSQL URL, required. The server runs its migrations at startup. |
| `OPENGARMIN_DATA_DIR` | Where raw bytes go when S3 is off. Default `./data` (`/data` in the image). |
| `OPENGARMIN_ALLOW_SIGNUP` | `true` allows sign-up after the first account. Default `false`. |
| `PORT` | HTTP port. Default `8080`. |
| `OPENGARMIN_S3_ENDPOINT` | S3 endpoint, such as `http://s3:7070`. Setting it turns S3 on. |
| `OPENGARMIN_S3_REGION` | S3 region. Default `us-east-1`. |
| `OPENGARMIN_S3_BUCKET` | Bucket for raw bytes. Required with an endpoint. |
| `OPENGARMIN_S3_ACCESS_KEY`, `OPENGARMIN_S3_SECRET_KEY` | S3 credentials. Required with an endpoint. |

Health check: `GET /healthz`.

### Tests

```sh
cd Server
TEST_DATABASE_URL=postgres://user:pass@localhost:5432/opengarmin_test swift test
```

The tests drop and recreate the `public` schema of the database in `TEST_DATABASE_URL`, so use a disposable database.
Without it the database tests are skipped. The S3 test runs when `OPENGARMIN_TEST_S3_ENDPOINT` (and the `_ACCESS_KEY`,
`_SECRET_KEY`, `_BUCKET`, `_REGION` variants) point at an S3 server, and is skipped otherwise.

## Thanks to

- [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) – the Garmin GFDI protocol, FIT handling, protobuf definitions and device list this app is based on.
- [garmin-ble](https://github.com/gwerneckp/garmin-ble) by gwerneckp – a clean Python implementation of the GFDI V2 / MLR stack and realtime metrics.

## License

AGPL-3.0, like the projects it builds on. Not affiliated with Garmin.
