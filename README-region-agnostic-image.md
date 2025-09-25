# Region-Agnostic Oracle Linux 8 Image Selection

This update removes hard-coded per-region image OCIDs and automatically discovers the latest Oracle Linux 8 image
in the **current region** of the stack/provider. It preserves your existing flow, and you can still override the image
via the optional `image_ocid` variable when needed (e.g., for locked exam builds).

## How it works
- Adds `rg_image_lookup.tf` that uses `data "oci_core_images"` filtered for Oracle Linux 8.
- Defines `local.rg_effective_image_ocid` which prefers `var.image_ocid` (if provided) otherwise falls back to the newest OL8 image.
- Rewrites `image_id` within `source_details {}` to reference `local.rg_effective_image_ocid`.

No other flow changes are required. The ORM-selected region is used automatically.
