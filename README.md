# AstroRover Gyro Remote

A Flutter app that uses your phone's **accelerometer** to steer the rover by tilting.

## How it works

| Tilt | Command sent |
|------|-------------|
| Forward (pitch +) | `forward` |
| Backward (pitch −) | `backward` |
| Right (roll +) | `right` |
| Left (roll −) | `left` |
| Flat (within dead zone) | `stop` |

Commands are sent at **10 Hz** to `http://<IP>/cmd?c=<dir>&s=<speed>` — same endpoint your web dashboard uses.

**Hold-to-drive** safety: the rover only moves while you hold the button. Release = immediate stop.

## Setup

```bash
flutter pub get
flutter run
```

### First launch
1. Tap **⚙** (top-right) to open Settings.
2. Enter your rover's IP address (shown on the LCD after boot).
3. Adjust motor speed (100–255) and dead zone angle.
4. Hit **SAVE**.

### Android note
`usesCleartextTraffic="true"` is already set in the manifest — required for plain `http://` to the ESP32.

### iOS note
`NSAllowsLocalNetworking` is set in `Info.plist` for local network HTTP.

## Dependencies

| Package | Use |
|---------|-----|
| `sensors_plus` | Accelerometer stream |
| `http` | HTTP GET to `/cmd` |
| `shared_preferences` | Persist IP/speed/deadzone |

## Sensor math

```
pitch = atan2(-y, sqrt(x² + z²))   # tilt forward/backward
roll  = atan2( x, sqrt(y² + z²))   # tilt left/right
```

The axis with the larger absolute angle wins (so pure forward doesn't accidentally turn).
