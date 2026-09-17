# Jawal device identity and reset model

Jawal is designed to behave as an Android **handheld/phone form factor** inside Windows while remaining honest about being a virtualized Android environment.

## Phone behavior

The Android product uses `PRODUCT_CHARACTERISTICS := phone` and Android's `handheld_core_hardware.xml` instead of the tablet core declaration inherited by generic Android-x86. This allows normal Android applications to choose phone layouts, portrait behavior, handheld features, permissions and UI paths where appropriate.

Jawal does **not** spoof a certified physical handset, hardware-backed attestation, Play Integrity verdicts, serial/IMEI values, or anti-fraud identifiers. Applications that explicitly require a certified physical device may still identify or reject a virtual environment.

## Factory reset

`فورمات الجوال` stops Android cleanly, deletes only the per-user `data.qcow2` overlay, recreates it from the pristine data template, and boots Android again.

A reset removes:

- installed applications
- application data
- Android accounts
- files stored inside the Jawal user-data volume
- Android user-scoped state generated inside that data volume

A reset keeps:

- the immutable JawalOS system image
- the Windows host application
- Jawal performance settings such as RAM/CPU preferences

The reset feature is intended for ordinary device lifecycle, testing, recovery, or starting with a clean Android environment. It is not designed to bypass service activation limits, device-binding controls, anti-abuse systems, DRM, or integrity checks.
