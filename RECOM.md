# Recommendations for `displaycameras` Stability and Recovery

This document outlines recommendations for improving the stability, error handling, and recovery capabilities of the `displaycameras` script.

## Immediate Improvement: Robust Camera Rotation Logic

The immediate issue is that video streams stretch and overlap during rotation, especially when the number of cameras does not match the number of defined window positions.

**Proposed Solution:**

Implement a more robust rotation logic within the existing shell scripts. This logic will correctly cycle all cameras through the available window positions.

*   **Scenario:** More cameras than window positions (e.g., 5 cameras, 4 windows).
*   **Behavior:** The script will rotate which cameras are displayed in the available windows. The extra camera(s) will be temporarily moved to an off-screen position (`-10000 -10000 -9000 -9000`). This ensures all cameras get screen time in sequence without visual glitches.
*   **Implementation:** This involves modifying `lib/rotation.sh` and `lib/stream.sh` to handle this off-screen positioning and correctly calculate the camera-to-window mapping during each rotation step.

---

## Long-Term Recommendations for Stability

For a more stable, error-free, and recoverable system, the following improvements are recommended.

### 1. Incremental Improvements (More Robust Shell Scripts)

We can make the existing scripts more resilient without a full rewrite.

*   **Smarter Health Checks:** The current `check_stream_health` is good, but it can be improved. A stream can be "Playing" but frozen. We could enhance the check to also get the stream's position (`getposition`) and compare it with the position from a few seconds ago. If it hasn't changed, the stream is likely frozen and needs a restart.
*   **Timeout on Control Commands:** The `omxplayer_dbuscontrol` script can occasionally hang if a player is unresponsive. We can wrap these calls with the `timeout` command (e.g., `timeout 2s omxplayer_dbuscontrol ...`). This prevents a single frozen player from halting the entire rotation and monitoring logic.
*   **Stateful Recovery:** When a stream fails and is repaired, it currently restarts in its original position. The script could be smarter, restarting it in the position it *should* be in according to the current rotation sequence.

### 2. Architectural Refactoring (Long-Term Stability)

The most stable, error-free, and recoverable solution would involve moving the core logic out of shell scripts and into a more robust language.

*   **Recommendation: Python Script.**
    A single Python script could replace the complex logic currently spread across `displaycameras`, `rotation.sh`, `stream.sh`, and `monitor.sh`.

*   **Why it would be better:**
    *   **Superior Error Handling:** Python's `try...except` blocks are far more powerful for catching and handling errors (like a failed DBus command or a crashed player) than shell error checking.
    *   **Reliable Process Management:** Instead of using fragile PID files, a Python script can launch and manage the `omxplayer` processes directly as subprocesses. It always knows their status and can react immediately if one crashes.
    *   **Advanced State Management:** Tracking which camera is in which window, rotation sequences, and health status is much simpler and less error-prone using Python dictionaries and objects instead of temporary files and shell variables.
    *   **Robust DBus Integration:** Using a proper Python DBus library (like `pydbus`) is more reliable and provides better feedback than shelling out to `omxplayer_dbuscontrol`.
