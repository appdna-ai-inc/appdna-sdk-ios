# Changelog

All notable changes to the AppDNA iOS SDK are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the project uses [Semantic Versioning](https://semver.org/).

## [1.0.84] — unreleased

Paywalls show the App Store's own price, billing period and free trial. Location fields can search
with Google as well as Mapbox. Lottie and Rive animations render for real. Two new delegate methods
let a host observe every tracked event and every piece of published config the SDK had to drop.

### Added

**SDK and host API**

- **`AppDNA.isReady`** (#855, #856). Answers whether `configure()` has finished. A `present…` call
  made before then used to return `false` with "Onboarding flow not found" (or no log at all),
  which sent integrators to check a flow id that was fine; the log now says the SDK is not ready
  yet. A bundled config with no section the SDK recognises now logs a warning naming the keys it
  found.
- **`AppDNALifecycleDelegate.onConfigurationIssue(surface:id:detail:)`** (#935). Called when part
  of a published flow, paywall, survey or message cannot be decoded and is dropped while the rest
  still renders. `detail` carries the coding path and the reason. The SDK also tracks
  `sdk_decode_dropped` with the same values and logs the detail at warning level. Each distinct
  problem is reported once per process.
- **`AppDNALifecycleDelegate.onEventTracked(name:properties:)`** (#1047). Called for every event the
  SDK tracks, right after it is queued, so you can forward AppDNA analytics into your own pipeline.
- **`LocationData.mapbox_id` and `LocationData.place_id`** (#1147). Set on an answer resolved from
  a tapped Mapbox or Google suggestion (see Location fields below).

**Paywalls**

- **Prices come from the App Store** (#923). A plan shows StoreKit's localized price for its
  product, in the user's own currency. The authored `price_display` is used whenever the store
  cannot answer, and a plan with `use_store_price: false` always shows the authored price.
  `paywall_view` now fires after the price lookup and carries `price_source` and
  `store_prices_resolved`.
- **Billing period and free trial from the App Store** (#933, #989). A plan that authors no period
  shows the store's period next to its price, phrased in the ten languages the console can
  localize into (English otherwise). The trial line uses, in order: `trial.label`,
  `trial_duration`, `trial.duration_days`, then the store's introductory free trial, shown only
  when the user is eligible for it. An ISO duration such as `P7D` is now phrased ("7 days free
  trial") instead of printed.
- **A plan's `period` is drawn** (#913, #909). It is a console field now and iOS renders it beside
  the price, as Android does.
- **Any section can be pinned to the bottom zone** with `zone: "bottom"` (#884, #903). Pinned
  sections sit above the purchase button in authored order. If the pinned group would take more
  than 55% of the screen, every pinned section except the purchase button goes back into the
  scrolling body.
- **Per-element container style** (#905, #910, #913). An element's `element_style` (border,
  radius, padding, opacity, shadow) is now drawn on plan labels, prices and badges, feature items,
  header title and subtitle, legal text, the purchase button, the restore link, reviews,
  testimonials, icon grids and social proof. It used to be dropped.
- **`tab_groups` plan layout** (#960). It used to fall back to a vertical stack.
- **Countdown variants and styling** (#980, #979, #978). A paywall countdown draws its `variant`
  (`digital`, `circular`, `flip`, `bar`) as the onboarding countdown does, and honours
  `label_font_weight`, `digit_font_size`, `digit_font_weight` and `text_color`. Unset keys draw as
  before.
- **Plans draw in `sort_order`** (#1056, #1097). A plan without a rank keeps its position.
- **A purchase button on a multi-plan paywall names the plan it will buy** (#1100, #1104), for
  example "Continue — Annual", so a plan tap the scroll view swallowed can no longer lead to a
  silent purchase of the previous plan. A single-plan paywall, a plan's own `cta_text`, and a
  label that already contains the plan's name are left alone. Set `cta.name_plan: false` to keep
  your text exactly, or `cta.plan_format` (`{cta}`, `{plan}`; translatable) to word it.
- **`onPaywallAction` is called** (#1074, #1076). iOS never called it. It now reports `ctaTapped`
  at the tap (also when the tap cannot proceed), `planChanged`, `linkTapped`, `custom` for an
  authored action the SDK does not recognise, and `featureSelected` when a feature row is tapped.
- **Social proof draws its caption and author** (#954, #955): the `app_rating` variant's `text`,
  and `author_name` wherever it is set.

**Onboarding**

- **Steps that advance without a button** (#921, #1014). `auto_advance_seconds` (0.1–60) advances
  the step after a delay; `wait_for_host: true` marks a step your app advances, so it never times
  out; `tap_anywhere_advances: true` advances on any tap a child element does not handle. All
  three go through the same advance as Continue (rules, events, required fields).
- **`skip_to_step`** (#1056) sets where Skip goes.
- **`dismiss_button_style`** (#1004) styles the ✕ that closes a flow: glyph, size, colour,
  background, radius and inset. The tap target stays 44×44. Unset keeps today's look.
- **Store reviews** (#896). `request_store_review: true` on a step asks iOS for the review prompt as
  the step appears; a button with `action: "rate_app"` opens the App Store's write-review page.
- **The flow's Celebration Effect is drawn** (#1026), on its first step (`on_appear`) or on every
  advance (`on_step_complete`).
- **Lottie and Rive animations render** (#982, #1024, #1017). They used to draw a placeholder box
  with the animation's file name. Both `.json` and `.lottie` files load. A Rive `rive_inputs` map
  is applied once the state machine has loaded (`bool` → boolean input, number → number input,
  string → trigger). **The SDK now depends on `lottie-ios` 4.6+ and `RiveRuntime` 6.x** (SwiftPM
  and CocoaPods), which adds roughly 3–5 MB to an app.
- **Sign in with Google draws Google's official mark** (#1003, #1030) instead of a bold "G", on a
  white chip when the button's own fill is too dark for it.
- **Info banner options** (#1005): `banner_hide_icon`, `banner_icon_align`, `banner_title_color`,
  `banner_subtitle_color`, a link (`banner_link_text`, `banner_link_url`, `banner_link_color`,
  `banner_link_size`), and an uploaded icon (`banner_icon_url`, `banner_icon_size`). Defaults draw
  the banner as before.
- **Form fields honour their authored style** (#985, #1053): border, focus-border and background
  colours, corner radius, `error_border_color` (while the field is in error), `font_weight`, and
  `field_style.font_size`. A field with no style keeps the system look.
- **`min_length` and `validate_format` are enforced** on text and URL fields (#984).
- **Category rows and live conditions** (#1013). `input_select` with `display_style:
  "bubble_scroll"` draws one horizontally scrolling row of pills, opening on its first option. A
  block's `visibility_condition` can name a field on the same step and reacts as it changes. A
  Segmented block honours its `display_style`.
- **A media gallery can carry a title** (`gallery_title`, `gallery_title_color`) (#1021).

**Location fields**

- **A tapped suggestion is resolved once more through AppDNA's proxy** (#1147). The stored answer
  is what that lookup returns and carries `mapbox_id` or `place_id`. A tap that cannot be resolved,
  or a step that moves on while it is resolving, stores the typed text.
- **Google as a location-search provider** (#1147, #1173). With a Google key under Settings >
  Location search, the dropdown shows the Google Maps logo, and a step that displays a Google
  answer draws a small "Google Maps" credit (an option's bottom sheet draws its own). Where an
  answer is stored or sent rather than shown (an option's value, a default value, a link or media
  URL, a header, and any template on a paywall, message, survey or push) the user's typed text is
  used. Editing a selected Google answer restarts from the typed text. See the onboarding docs for
  the full rule.

**Surveys, push and events**

- **Likert questions render** (#998). They used to show the question over empty space.
- **`push_dismissed` on iOS** (#968, #987). Every AppDNA push now gets a notification category
  with a dismiss action, so swiping a push away is reported, and never counted as a tap. The
  button-less category is registered at `configure()`.
- **`store_listing_opened` carries `store`** (`app_store` / `google_play`) (#974), a property both
  platforms send.

### Changed

- **Unstyled text follows the step's background** (#1194, #1196, #1198). Text, headings, field
  labels, typed text, placeholders, the cursor, the password field and the back / close / Skip
  controls default to light ink on a dark, gradient or image step, and stay dark on a light one.
  They used to follow the phone's appearance, so a dark-mode phone drew white text on a white
  step. Authored colours still win.
- **A paywall's colours follow its document, not the phone** (#891, #947, #938). Text, icons,
  dots and tiles nobody coloured are read off the page background. They used to use system
  colours, so the same paywall drew differently in light and dark appearance, and a carousel or
  reviews carousel on a white page could be blank.
- **Store reviews are never pre-screened** (#897). If any branch of a survey asks for a review,
  every respondent who finishes is eligible and the OS decides the rest; the respondent's own
  branch still runs. `review_prompt_accepted` and `review_prompt_declined` are no longer sent,
  because neither store reports the outcome.
- **A survey trigger's unknown `frequency` means `once`**, the documented default (#1064).
- **Date-picker range messages** now read "Date is before the earliest allowed date" / "Date is
  after the latest allowed date", matching Android (#977).
- **Markdown outside the supported subset is converted, not printed** (#893, #900): `# Heading`
  draws bold, `> quote` italic, `- item` as "• item", a table row as "a · b", and inline code
  without its backticks.
- **The location field's return key reads Search** on the form step, as it does on the content
  block (#1195).
- **A user trait counts as present only when it holds a non-null value** (#1212), in audience
  rules, matching the server.

### Fixed

**Paywalls & billing**

- **A failed purchase leaves the paywall usable** (#1105, #1107, #1111). A tap on the purchase
  button while the failure banner is up buys again; only a tap on the banner hides it (every tap
  used to just hide the banner). The banner's retry runs the purchase button's own purchase; it
  used to only hide the banner. An empty message or retry text counts as unset.
- **The particle effect fires on its authored trigger** (#997, #1103): `on_appear` when the paywall
  shows, `on_purchase` once a purchase has succeeded. It used to start on the purchase-button tap
  and keep running over a payment-failed message.
- **A purchase button that cannot buy is disabled and dimmed** (#1075), as on Android.
- **A plan's own `cta_text` reaches the paywall's root purchase button** (#1081).
- **Plan rows report their selected state to VoiceOver** (#1084).
- **A paywall is presented from whichever screen is on top when it opens** (#1078). A presentation
  UIKit refuses is reported through `onConfigurationIssue`.
- **A named feature icon draws** (#1067). `icon: "check"` drew nothing because it is not an SF
  Symbol name.
- **The divider's label draws its `label_bg_color`** (#976), as on Android.
- **The close button no longer covers the header title** (#881, #894, #895). The header reserves
  room for it; a legacy `dismiss.type: "swipe"` reserves none, as on Android.
- **A countdown's digit chip is visible on a light page** (#979).

**Onboarding**

- **A button with an action the SDK does not recognise (for example `continue`) advances with the
  step's answers** (#1091). It used to advance and discard them.
- **Coming back to a question step shows the options the user chose**, with Continue enabled
  (#1188).
- **A dropdown-style select opens the picked option's bottom sheet** and records the pick for
  `{{selected.…}}` (#1172).
- **`{{onboarding.<step>.<field>.city}}` resolves** (#1158). A token now walks into a structured
  answer to any depth.
- **A circular countdown's ring sweeps** (#1066). It sat at 75% for the whole countdown.
- **A Multi-buttons border colour draws a border, and `background_full_bleed` reaches the screen
  edges** (#1007, #1006).
- **The Location content block honours its settings** (#963, #964). It now searches through
  AppDNA's proxy like the form-step field, so Location Type, bias country, language and minimum
  characters apply (it searched Apple's place index for addresses from the first keystroke), and
  its answer includes `state_code` and the place's time zone. A type the proxy does not accept is
  dropped instead of returning no suggestions. A suggestion no longer reads "Kyoto / Kyoto, Japan".

**Surveys**

- **An emoji answer's sentiment is read against the question's own scale** (#1011). Answers on the
  console's default scale or any custom scale were neutral, so `on_positive` / `on_negative`
  follow-ups never ran.
- **The feedback form appears after a negative answer** (#901). It was presented on the survey
  sheet while it was being dismissed, so it never showed.
- **`feedback_form_dismissed` is recorded when the form is taken away with its presenter**, with a
  new `reason` (#920).
- **A choice option with an icon object is shown, and draws its icon** (#999). The whole option
  used to be dropped.
- **A survey trigger's `neq` condition is no longer inverted**; `in` and `not_in` are implemented
  (#1064).
- **A review request spends quota only when the prompt is actually requested** (#939). With no
  active window scene it used to count, and report, a prompt StoreKit was never asked for.
- **A survey skipped for its love-score or minimum-sessions rule says so** in the debug log (#1115).

**Identity, targeting & config**

- **`identify` no longer crashes on a non-JSON trait** (#1202, #1208, #1211). A `LocationData`
  trait is sent as its answer map; any other non-JSON value is dropped with a warning. A `nil`
  trait is kept as JSON null, and `{{user.x | fallback}}` takes its fallback for it.
- **An audience operator the SDK does not implement matches nobody** (#1213). It used to match
  every user. `not_exists` is implemented.
- **One wrongly-typed field no longer drops a whole flow, paywall or survey** (#919, #936). The
  field is ignored and reported, and the rest renders.
- **A colour the SDK cannot parse is transparent** (#885). A six-letter CSS name such as `orange`
  drew opaque black.
- **A deferred deep link survives a failed first lookup** (#1063). A launch with no network used to
  lose the link for good; up to four failed attempts are retried on later launches.
- **The SDK advertises only gzip** (#857). It also offered `deflate`, which it cannot decode.

### Removed

- **Inert config fields** (#992, #996): `PaywallConfig`'s `affectsPrice`, `ContentBlock.justify`,
  and the Lottie `lottie_json` / `color_overrides` keys. None of them was drawn; use `lottie_url`
  and `row_distribution`. A published document that still carries them decodes as before.
