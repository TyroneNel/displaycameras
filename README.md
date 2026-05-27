# displaycameras - Raspberry Pi RTSP Camera Viewer

A set of scripts to display multiple RTSP camera streams on a Raspberry Pi using the hardware-accelerated `omxplayer`. It is designed to be a reliable, 24/7 monitoring solution that runs as a system service.

---

## ⚠️ Important Notice: `omxplayer` Deprecation

As of the Debian Bullseye release, `omxplayer` and its associated hardware acceleration libraries are no longer included in the standard Raspberry Pi OS distribution.

-   **Recommended OS:** For the simplest setup, use the **Raspbian Buster** (or older) Lite image.
-   **Bullseye/Newer OS:** If you are using a newer OS, you **must** follow the manual installation steps below for `omxplayer` to function.

---

## 1. Manual `omxplayer` Installation (for Bullseye/Newer)

If you are not using Raspbian Buster, follow these steps before running the main installer.

### Step 1: Install Legacy Firmware Libraries

The required hardware acceleration libraries must be manually copied from an older firmware version.

1.  **Install `git`:**
    ```bash
    sudo apt-get update
    sudo apt-get install -y git
    ```

2.  **Clone the `oldstable` firmware branch:**
    ```bash
    git clone --depth 1 --branch oldstable https://github.com/raspberrypi/firmware.git /tmp/firmware
    ```

3.  **Copy the required libraries to the system:**
    ```bash
    sudo cp /tmp/firmware/opt/vc/lib/libbrcmEGL.so /opt/vc/lib/
    sudo cp /tmp/firmware/opt/vc/lib/libbrcmGLESv2.so /opt/vc/lib/
    sudo cp /tmp/firmware/opt/vc/lib/libopenmaxil.so /opt/vc/lib/
    sudo cp /tmp/firmware/opt/vc/lib/libvchostif.a /opt/vc/lib/
    ```

### Step 2: Install `omxplayer` Package

1.  **Download the `omxplayer` .deb package:**
    ```bash
    wget https://archive.raspberrypi.org/debian/pool/main/o/omxplayer/omxplayer_20190723+gitf543a0d-1+bullseye_armhf.deb -P /tmp
    ```

2.  **Install the package:**
    ```bash
    sudo dpkg -i /tmp/omxplayer_20190723+gitf543a0d-1+bullseye_armhf.deb
    ```

3.  **Fix any broken dependencies:**
    ```bash
    sudo apt-get install -f -y
    ```

---

## 2. `displaycameras` Installation

After ensuring the prerequisites are met (including the manual steps above if needed), you can install `displaycameras`.

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/Anonymousdog/displaycameras.git
    cd displaycameras
    ```

2.  **Make the installer executable:**
    ```bash
    chmod +x ./install.sh
    ```

3.  **Run the installer:**
    The script will install required packages like `fbi`, `logrotate`, and `dos2unix`.
    ```bash
    sudo ./install.sh
    ```

---

## 3. Configuration

Configuration is split into two main files located in `/etc/displaycameras/`.

### `displaycameras.conf`
This file contains global settings like screen blanking (`blank="true"`) and stream rotation (`rotate="true"`).

### `layout.conf.default`
This is where you define your cameras and the window layout.

1.  **Define Camera Names:** Create a unique name for each camera. Names must only contain `A-Z`, `a-z`, `0-9`, and `_`.
    ```bash
    camera_names=(
        "FrontDoor"
        "Driveway"
    )
    ```

2.  **Define Camera RTSP Feeds:** Add the corresponding RTSP URL for each camera.
    ```bash
    camera_feeds=(
        "rtsp://192.168.1.10:7447/your_front_door_stream"
        "rtsp://192.168.1.11:7447/your_driveway_stream"
    )
    ```

3.  **Define Window Positions:** Specify the screen coordinates for each window in the format `"x1 y1 x2 y2"`.
    ```bash
    window_positions=(
        "0 0 960 540"      # Top-left
        "960 0 1920 540"   # Top-right
    )
    ```

---

## 4. Service Management

The installer registers `displaycameras` as a `systemd` service.

-   **Start:** `sudo systemctl start displaycameras`
-   **Stop:** `sudo systemctl stop displaycameras`
-   **Restart:** `sudo systemctl restart displaycameras`
-   **Check Status:** `sudo systemctl status displaycameras`
-   **Enable on Boot:** `sudo systemctl enable displaycameras`
-   **Disable on Boot:** `sudo systemctl disable displaycameras`

For more detailed debugging, use the script's own status command:
`sudo /usr/bin/displaycameras status`

---

## 5. Troubleshooting

-   **Check the logs:** All output is logged to `/var/log/displaycameras.log`.
-   **Test a stream URL directly:** Run this command to see if `omxplayer` can play your stream.
    ```bash
    omxplayer --no-keys --no-osd --avdict rtsp_transport:tcp "YOUR_RTSP_URL_HERE" --live -n -1 --timeout 30
    ```

---

## 6. Removal

1.  **Stop and disable the service:**
    ```bash
    sudo systemctl stop displaycameras.service
    sudo systemctl disable displaycameras.service
    ```
2.  **Remove all installed files:**
    ```bash
    sudo rm -R /etc/displaycameras
    sudo rm /etc/systemd/system/displaycameras.service
    sudo rm /usr/bin/omxplayer_dbuscontrol /usr/bin/black.png /usr/bin/displaycameras
    sudo rm /etc/cron.d/repaircameras
    sudo rm -R /usr/lib/displaycameras
    sudo systemctl restart cron
    ```