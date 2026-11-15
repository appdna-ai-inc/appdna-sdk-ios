# Important: AppDNA iOS SDK is Proprietary Software

**The AppDNA iOS SDK is not open source.** This GitHub repository is publicly visible only for marketing, evaluation, and reference purposes. **You may not download, install, run, modify, or use the SDK without a Commercial Agreement with AppDNA AI, Inc.**

## What you can do (without an agreement)

- View this repository on GitHub through your browser
- Read the public documentation at https://docs.appdna.ai
- Evaluate whether AppDNA is right for your business

## What you cannot do (without an agreement)

- Clone, download, or fork this repository for use
- Install the SDK in any application — including for development, testing, or staging
- Compile, build, or run the SDK or any part of it
- Modify the SDK or create derivative works
- Redistribute the SDK to anyone
- Reverse engineer the SDK
- Use any part of the SDK to build a competing product

A Commercial Agreement means either:
- AppDNA's **Terms of Service** at https://appdna.ai/terms (self-serve customers), accepted electronically; or
- A signed **Statement of Work** or **Master Services Agreement** (enterprise customers).

To get started, visit **https://appdna.ai** or email **sales@appdna.ai**.

## Existing AppDNA customers

If you are already an AppDNA customer with a current Commercial Agreement, your rights are governed by that agreement, not by this LICENSE file. Use the SDK as your agreement permits.

## Why publish source if it's proprietary?

We make the source visible because we believe transparency builds trust — you can review the code that runs in your app before you sign with us, our customers can audit security, and developers can understand integration patterns. But trust requires that the source is also protected: it represents years of investment in the AppDNA Console and SDK, and we license it commercially to fund continued development.

## Prior versions (before v1.0.60)

Versions of the iOS SDK released before **v1.0.60** were distributed under the **MIT License**. Rights you obtained under MIT to those specific prior versions are unaffected by this License. **All current and future versions, starting with v1.0.60, are governed by this proprietary License** (see the LICENSE file).

If you are running v1.0.59 or earlier in production, see [DEPRECATION_NOTICE.md](./DEPRECATION_NOTICE.md) for the migration timeline.

## Questions

- Licensing: legal@appdna.ai
- Sales / commercial inquiries: sales@appdna.ai
- Technical: support@appdna.ai
- Privacy / DPA: privacy@appdna.ai

---

© 2026 AppDNA AI, Inc. All rights reserved. "AppDNA" and the AppDNA logo are trademarks of AppDNA AI, Inc.

---

## Third-party assets

### Google's "G" mark — `appdna_google_g.png`

Google's official mark for **Sign in with Google** buttons, shipped UNMODIFIED.

- Source: https://developers.google.com/identity/images/g-logo.png
- Fetched: 2026-10-19 · 33,661 bytes · 200 × 204 RGBA PNG
- Terms: https://developers.google.com/identity/branding-guidelines

Google's branding guidelines require the official asset, used unmodified, on a sign-in button. That
is the only place this SDK draws it: the `social_login` block's `google` provider. It is not
resized by hand, not recoloured, and not offered as a general-purpose icon.

🔴 Do not edit the file. Re-fetch it from the URL above if it ever needs updating, so what ships
stays byte-identical to what Google publishes. On Android it must live in `res/` as a `.png` and
NOTHING else: a sidecar file beside it fails `packageDebugResources` with "The file name must end
with .xml or .png", which is why this note is here rather than next to the asset.

### Facebook logo — `appdna_facebook_mark_primary.png`, `appdna_facebook_mark_secondary.png`

Meta's official **Facebook logo**, shipped UNMODIFIED, in the two expressions Meta publishes. Each
file is a PNG from Meta's Facebook Brand Asset Pack, renamed only:

| File | Meta's file | MD5 |
|---|---|---|
| `appdna_facebook_mark_primary.png` | `Logo/Primary Logo/Facebook_Logo_Primary.png` (Facebook Blue, white "f") | `e4da23704f27c9df07e6c21a13e28bfd` |
| `appdna_facebook_mark_secondary.png` | `Logo/Secondary Logo/Facebook_Logo_Secondary.png` (white, transparent "f") | `14150615fbf19b940f52520488fe40fb` |

- Source: https://www.meta.com/brand/resources/facebook/logo/ ("Logo pack")
- Fetched: 2026-11-15 · 2084 × 2084 RGBA PNGs
- Terms: Meta's brand resources guidelines on that page, and https://www.facebook.com/terms.php

The only place this SDK draws it is the `social_login` block's `facebook` provider. Meta's usage rules
it follows: the logo appears only in Facebook Blue or white (the primary mark on light surfaces, the
secondary mark on a Facebook Blue or dark one, never recoloured); it is at least 16px wide (drawn at
20); it keeps half a logo's width from other content (10 from the label); and it is complete, with no
outline, shadow or effect. The renderer decodes it at a reduced size, which scales it and does not
edit it.

🔴 Do not edit the files. Re-download Meta's pack from the URL above if they ever need updating, so
what ships stays byte-identical to what Meta publishes.

### Google Maps attribution logo — `appdna_google_maps_logo_*.png`

Google's official **"Google Maps"** attribution logo, shipped UNMODIFIED, in four variants. Each
file is the `_4x.png` of one folder of Google's attribution asset pack, renamed only:

| File | Google's file | MD5 |
|---|---|---|
| `appdna_google_maps_logo_gray.png` | `GoogleMaps_Logo_Gray/GoogleMaps_Logo_Gray_4x.png` | `0b8fbbf64bde9f21511269bfabe8db4b` |
| `appdna_google_maps_logo_white.png` | `GoogleMaps_Logo_White/GoogleMaps_Logo_White_4x.png` | `bc9597c52f21db85bf265fb1a5979253` |
| `appdna_google_maps_logo_light_outline.png` | `GoogleMaps_Logo_WithLightOutline/GoogleMaps_Logo_WithLightOutline_4x.png` | `863468e90a39e1fa8a69d1601af49ec4` |
| `appdna_google_maps_logo_dark_outline.png` | `GoogleMaps_Logo_WithDarkOutline/GoogleMaps_Logo_WithDarkOutline_4x.png` | `2b7fc9319332b0b1ddafed9d72c221f3` |

- Source: https://developers.google.com/static/maps/documentation/images/Google_Maps_Attribution_Assets.zip
  (linked from the attribution guidelines below)
- Fetched: 2026-10-28 · zip MD5 `ea6c3d1f85f2f0ef6d337dc25bdeaac3` · 91,462 bytes
- Terms and usage rules: https://developers.google.com/maps/documentation/geocoding/policies
  (the "Google Maps attribution" section, shared with the Places API policies)

Google requires this attribution wherever Places or Geocoding content is shown without a Google
map. The SDK draws it in exactly two places: under a location dropdown that lists Google
suggestions, and beside a location field whose answer came from Google. It is drawn 16 pt high
(Google's range is 16–19 dp), with 10 pt clear space on the left, right and top and 5 pt below,
with the accessibility label "Google Maps". The plain gray and white variants go on plain light and
dark surfaces; the outlined variants on busy ones (an image or gradient behind the field), as the
guidelines direct. Where a logo cannot be drawn, the SDK spells out "Google Maps" in text, which
the guidelines also allow.

🔴 Do not edit the files. Re-fetch the asset pack from the URL above if they ever need updating.
