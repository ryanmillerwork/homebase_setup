# stim2
A cross platform system for visual stimulus presentation

## Design

stim2 is an OpenGL/GLES based program for showing graphics objects. It uses GLFW to open and initialize its display. The core role of the main program is to provide containers (graphics lists). These objects are created using "stimdlls", which define a large variety of graphics objects:

* metagroups
* polygons
* images
* motionpatches
* text
* svg objects
* user defined shaders with uniform controls
* spine2d animations
* video
* box2d worlds
* tilemap game environments

Examples of these are demonstrated through the stim2 development page, which is hosted by stim2 at [stim2-dev](http://localhost:4613/stim2-dev.html) and a terminal for interacting with the program is accessible at [terminal](http://localhost:4613/).

The system allows mixing and matching of objects in a single frame, and supports animation.

The system achieves frame accurate timing by running in C++, but configuration and frame callbacks are programming in Tcl, which provides high level access to the underlying graphics objects.

Extensive library support for numerical processing, curve and image creation, and physics computations are made available through the extensive dlsh/tcl packages that are available within any stim2 script.

## Coordinate System

The program uses degrees visual angle as its core coordinate system (up and right positive). This of course depends on the size of the display **and** the distance to the display. These can be set using the following commands

```
screen_set ScreenWidthCm     10
screen_set ScreenHeightCm     6
screen_set DistanceToMonitor 25
```

and to have these take effect

```
screen_config
```

For real experiment systems, it is of course essential to get these numbers correct. For development systems, where the stim2 window might not be full screen, you would want to simulate settings that would be most like your target system.

## Command Line Arguments

| Option | Long Form | Description | Default |
|--------|-----------|-------------|---------|
| `-v` | `--verbose` | Enable verbose output (renderer info, video mode) | off |
| `-b` | `--borderless` | Create borderless window | off |
| `-w` | `--width` | Window width in pixels | 580 |
| `-h` | `--height` | Window height in pixels | 340 |
| `-x` | `--xpos` | Window X position | 10 |
| `-y` | `--ypos` | Window Y position | 10 |
| `-r` | `--refresh` | Display refresh rate (Hz) | monitor default |
| `-t` | `--timer` | Timer interval (ms) | — |
| `-F` | `--fullscreen` | Run in fullscreen mode | off |
| `-f` | `--file` | Tcl startup script to source | none |
| | `--help` | Print help message | |

### Examples

```bash
# Run fullscreen on primary monitor
stim2 -F

# Windowed 800x600 at position (100, 100)
stim2 -w 800 -h 600 -x 100 -y 100

# Borderless window with startup script
stim2 -b -f experiment.tcl

# Verbose mode for debugging
stim2 -v -F
```

## Example: Monitor Configuration

Create `~/.config/stim2/monitor.tcl` to set screen parameters:

```tcl
# Monitor-specific settings
screen_set ScreenWidthCm       52.0
screen_set ScreenHeightCm      32.5
screen_set DistanceToMonitor   57.0
```

## Startup configuration files

The default install includes a startup config file that:

1. Loads shared library plugins from `<exe_dir>/stimdlls/`
2. Sources system-wide scripts from `<exe_dir>/local/` (Linux only)
3. Sources user scripts from `~/.config/stim2/`
4. Calls `screen_config` to apply display settings



## Linux Systemd Service

For dedicated stimulus presentation systems (e.g., Raspberry Pi, embedded Linux), stim2 can run as a systemd service using [Cage](https://github.com/cage-kiosk/cage) as a minimal Wayland compositor.

### Service File

Install the service file to `/etc/systemd/system/stim2.service`:

```ini
[Unit]
Description=Stim2 Stimulus Presentation

[Service]
Type=simple
Environment=XDG_RUNTIME_DIR=/tmp
ExecStart=/usr/bin/cage -- /usr/local/stim2/stim2 -F -f /usr/local/stim2/config/linux.cfg
Restart=always
RestartSec=5
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=50

[Install]
WantedBy=multi-user.target
```

### Installation

```bash
# Copy service file
sudo cp /usr/local/stim2/systemd/stim2.service /etc/systemd/system/

# Reload systemd and enable service
sudo systemctl daemon-reload
sudo systemctl enable stim2.service

# Start/stop/restart
sudo systemctl start stim2
sudo systemctl stop stim2
sudo systemctl restart stim2

# Check status and logs
sudo systemctl status stim2
journalctl -u stim2 -f
```

### Key Settings

| Setting | Value | Purpose |
|---------|-------|---------|
| `CPUSchedulingPolicy=fifo` | FIFO | Real-time scheduling for consistent frame timing |
| `CPUSchedulingPriority=50` | 50 | Elevated priority (1-99 range) |
| `Restart=always` | — | Auto-restart on crash or exit |
| `RestartSec=5` | 5s | Delay before restart |

### Prerequisites

- **Cage**: Minimal Wayland compositor (`sudo apt install cage`)
- **stim2** installed to `/usr/local/stim2/`
- Configuration file at `/usr/local/stim2/config/linux.cfg`

Adjust paths in `ExecStart` to match your installation.