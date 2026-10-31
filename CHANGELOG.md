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

- **`AppDNA.isReady`**. Answers whether `configure()` has finished. A `present…` call
  made before then used to return `false` with "Onboarding flow not found" (or no log at all),
  which sent integrators to check a flow id that was fine; the log now says the SDK is not ready
  yet. A bundled config with no section the SDK recognises now logs a warning naming the keys it
  found.
- **`AppDNALifecycleDelegate.onConfigurationIssue(surface:id:detail:)`**. Called when part
  of a published flow, paywall, survey or message cannot be decoded and is dropped while the rest
  still renders. `detail` carries the coding path and the reason. The SDK also tracks
  `sdk_decode_dropped` with the same values and logs the detail at warning level. Each distinct
  problem is reported once per process.
- **`AppDNALifecycleDelegate.onEventTracked(name:properties:)`**. Called for every event the
  SDK tracks, right after it is queued, so you can forward AppDNA analytics into your own pipeline.
- **`LocationData.mapbox_id` and `LocationData.place_id`**. Set on an answer resolved from
  a tapped Mapbox or Google suggestion (see Location fields below).

**Paywalls**

- **Prices come from the App Store**. A plan shows StoreKit's localized price for its
  product, in the user's own currency. The authored `price_display` is used whenever the store
  cannot answer, and a plan with `use_store_price: false` always shows the authored price.
  `paywall_view` now fires after the price lookup and carries `price_source` and
  `store_prices_resolved`.
- **Billing period and free trial from the App Store**. A plan that authors no period
  shows the store's period next to its price, phrased in the ten languages the console can
  localize into (English otherwise). The trial line uses, in order: `trial.label`,
  `trial_duration`, `trial.duration_days`, then the store's introductory free trial, shown only
  when the user is eligible for it. An ISO duration such as `P7D` is now phrased ("7 days free
  trial") instead of printed.
- **A plan's `period` is drawn**. It is a console field now and iOS renders it beside
  the price, as Android does.
- **Any section can be pinned to the bottom zone** with `zone: "bottom"`. Pinned
  sections sit above the purchase button in authored order. If the pinned group would take more
  than 55% of the screen, every pinned section except the purchase button goes back into the
  scrolling body.
- **Per-element container style**. An element's `element_style` (border,
  radius, padding, opacity, shadow) is now drawn on plan labels, prices and badges, feature items,
  header title and subtitle, legal text, the purchase button, the restore link, reviews,
  testimonials, icon grids and social proof. It used to be dropped.
- **`tab_groups` plan layout**. It used to fall back to a vertical stack.
- **Countdown variants and styling**. A paywall countdown draws its `variant`
  (`digital`, `circular`, `flip`, `bar`) as the onboarding countdown does, and honours
  `label_font_weight`, `digit_font_size`, `digit_font_weight` and `text_color`. Unset keys draw as
  before.
- **Plans draw in `sort_order`**. A plan without a rank keeps its position.
- **A purchase button on a multi-plan paywall names the plan it will buy**, for
  example "Continue — Annual", so a plan tap the scroll view swallowed can no longer lead to a
  silent purchase of the previous plan. A single-plan paywall, a plan's own `cta_text`, and a
  label that already contains the plan's name are left alone. Set `cta.name_plan: false` to keep
  your text exactly, or `cta.plan_format` (`{cta}`, `{plan}`; translatable) to word it.
- **`onPaywallAction` is called**. iOS never called it. It now reports `ctaTapped`
  at the tap (also when the tap cannot proceed), `planChanged`, `linkTapped`, `custom` for an
  authored action the SDK does not recognise, and `featureSelected` when a feature row is tapped.
- **Social proof draws its caption and author**: the `app_rating` variant's `text`,
  and `author_name` wherever it is set.

**Onboarding**

- **Steps that advance without a button**. `auto_advance_seconds` (0.1–60) advances
  the step after a delay; `wait_for_host: true` marks a step your app advances, so it never times
  out; `tap_anywhere_advances: true` advances on any tap a child element does not handle. All
  three go through the same advance as Continue (rules, events, required fields).
- **`skip_to_step`** sets where Skip goes.
- **`dismiss_button_style`** styles the ✕ that closes a flow: glyph, size, colour,
  background, radius and inset. The tap target stays 44×44. Unset keeps today's look.
- **Store reviews**. `request_store_review: true` on a step asks iOS for the review prompt as
  the step appears; a button with `action: "rate_app"` opens the App Store's write-review page.
- **The flow's Celebration Effect is drawn**, on its first step (`on_appear`) or on every
  advance (`on_step_complete`).
- **Lottie and Rive animations render**. They used to draw a placeholder box
  with the animation's file name. Both `.json` and `.lottie` files load. A Rive `rive_inputs` map
  is applied once the state machine has loaded (`bool` → boolean input, number → number input,
  string → trigger). **The SDK now depends on `lottie-ios` 4.6+ and `RiveRuntime` 6.x** (SwiftPM
  and CocoaPods), which adds roughly 3–5 MB to an app.
- **Sign in with Google draws Google's official mark** instead of a bold "G", on a
  white chip when the button's own fill is too dark for it.
- **Info banner options**: `banner_hide_icon`, `banner_icon_align`, `banner_title_color`,
  `banner_subtitle_color`, a link (`banner_link_text`, `banner_link_url`, `banner_link_color`,
  `banner_link_size`), and an uploaded icon (`banner_icon_url`, `banner_icon_size`). Defaults draw
  the banner as before.
- **Form fields honour their authored style**: border, focus-border and background
  colours, corner radius, `error_border_color` (while the field is in error), `font_weight`, and
  `field_style.font_size`. A field with no style keeps the system look.
- **`min_length` and `validate_format` are enforced** on text and URL fields.
- **Category rows and live conditions**. `input_select` with `display_style:
  "bubble_scroll"` draws one horizontally scrolling row of pills, opening on its first option. A
  block's `visibility_condition` can name a field on the same step and reacts as it changes. A
  Segmented block honours its `display_style`.
- **A dropdown-style Select can be multi-select.** With `multi_select`, the default dropdown is a
  multi-pick menu: each pick toggles that option, a check marks each picked option, and the field
  shows the picked labels in pick order. The menu closes after each pick. The answer is a list, the
  options are recorded for `{{selected.<field_id>.<n>.…}}` in pick order, and `max_selections` caps
  the picks, exactly as in the list styles. Before, a dropdown stored one value whatever
  `multi_select` said.
- **A media gallery can carry a title** (`gallery_title`, `gallery_title_color`).

**Location fields**

- **A tapped suggestion is resolved once more through AppDNA's proxy**. The stored answer
  is what that lookup returns and carries `mapbox_id` or `place_id`. A tap that cannot be resolved,
  or a step that moves on while it is resolving, stores the typed text.
- **Google as a location-search provider**. With a Google key under Settings >
  Location search, the dropdown shows the Google Maps logo at the top of its list, directly under
  the field (so it stays on screen with the keyboard up), a field holding a Google answer keeps
  the logo in view with it (on a short screen, such as landscape, the step scrolls them above the
  pinned buttons together), and a step that displays a Google answer draws a small "Google Maps"
  credit (an option's bottom sheet draws its own). Where an answer is stored or sent rather than
  shown (an option's value, a default value, a link or media URL, a header, and any template on a
  paywall, message, survey or push) the user's typed text is used. Editing a selected Google
  answer restarts from the typed text. See the onboarding docs for the full rule.

**Surveys, push and events**

- **Likert questions render**. They used to show the question over empty space.
- **`push_dismissed` on iOS**. Every AppDNA push now gets a notification category
  with a dismiss action, so swiping a push away is reported, and never counted as a tap. The
  button-less category is registered at `configure()`.
- **`store_listing_opened` carries `store`** (`app_store` / `google_play`), a property both
  platforms send.

### Changed

- **Unstyled text follows the step's background**. Text, headings, field
  labels, typed text, placeholders, the cursor, the password field and the back / close / Skip
  controls default to light ink on a dark, gradient or image step, and stay dark on a light one.
  They used to follow the phone's appearance, so a dark-mode phone drew white text on a white
  step. Authored colours still win.
- **A paywall's colours follow its document, not the phone**. Text, icons,
  dots and tiles nobody coloured are read off the page background. They used to use system
  colours, so the same paywall drew differently in light and dark appearance, and a carousel or
  reviews carousel on a white page could be blank.
- **Store reviews are never pre-screened**. If any branch of a survey asks for a review,
  every respondent who finishes is eligible and the OS decides the rest; the respondent's own
  branch still runs. `review_prompt_accepted` and `review_prompt_declined` are no longer sent,
  because neither store reports the outcome.
- **A survey trigger's unknown `frequency` means `once`**, the documented default.
- **Date-picker range messages** now read "Date is before the earliest allowed date" / "Date is
  after the latest allowed date", matching Android.
- **Markdown outside the supported subset is converted, not printed**: `# Heading`
  draws bold, `> quote` italic, `- item` as "• item", a table row as "a · b", and inline code
  without its backticks.
- **The location field's return key reads Search** on the form step, as it does on the content
  block.
- **A user trait counts as present only when it holds a non-null value**, in audience
  rules, matching the server.

### Fixed

**Paywalls & billing**

- **A failed purchase leaves the paywall usable**. A tap on the purchase
  button while the failure banner is up buys again; only a tap on the banner hides it (every tap
  used to just hide the banner). The banner's retry runs the purchase button's own purchase; it
  used to only hide the banner. An empty message or retry text counts as unset.
- **The particle effect fires on its authored trigger**: `on_appear` when the paywall
  shows, `on_purchase` once a purchase has succeeded. It used to start on the purchase-button tap
  and keep running over a payment-failed message.
- **A purchase button that cannot buy is disabled and dimmed**, as on Android.
- **A plan's own `cta_text` reaches the paywall's root purchase button**.
- **Plan rows report their selected state to VoiceOver**.
- **A paywall is presented from whichever screen is on top when it opens**. A presentation
  UIKit refuses is reported through `onConfigurationIssue`.
- **A named feature icon draws**. `icon: "check"` drew nothing because it is not an SF
  Symbol name.
- **The divider's label draws its `label_bg_color`**, as on Android.
- **The close button no longer covers the header title**. The header reserves
  room for it; a legacy `dismiss.type: "swipe"` reserves none, as on Android.
- **A countdown's digit chip is visible on a light page**.

**Onboarding**

- **A button with an action the SDK does not recognise (for example `continue`) advances with the
  step's answers**. It used to advance and discard them.
- **Coming back to a question step shows the options the user chose**, with Continue enabled.
- **A dropdown-style select opens the picked option's bottom sheet** and records the pick for
  `{{selected.…}}`.
- **A multi-select field's stored value draws and records the same way on iOS and Android.** A list
  counts as the selection only when every element is a String. A single answer, a number or a list
  holding one (`[1]`, `["a", 2]`) draws nothing checked, also when a host writes it mid-step, so the
  next tap starts from an empty list. A selection on a host-data-scoped Select is pruned only when it
  is such a list.
- **`{{onboarding.<step>.<field>.city}}` resolves**. A token now walks into a structured
  answer to any depth.
- **A circular countdown's ring sweeps**. It sat at 75% for the whole countdown.
- **A Multi-buttons border colour draws a border, and `background_full_bleed` reaches the screen
  edges**.
- **The Location content block honours its settings**. It now searches through
  AppDNA's proxy like the form-step field, so Location Type, bias country, language and minimum
  characters apply (it searched Apple's place index for addresses from the first keystroke), and
  its answer includes `state_code` and the place's time zone. A type the proxy does not accept is
  dropped instead of returning no suggestions. A suggestion no longer reads "Kyoto / Kyoto, Japan".

**Surveys**

- **An emoji answer's sentiment is read against the question's own scale**. Answers on the
  console's default scale or any custom scale were neutral, so `on_positive` / `on_negative`
  follow-ups never ran.
- **The feedback form appears after a negative answer**. It was presented on the survey
  sheet while it was being dismissed, so it never showed.
- **`feedback_form_dismissed` is recorded when the form is taken away with its presenter**, with a
  new `reason`.
- **A choice option with an icon object is shown, and draws its icon**. The whole option
  used to be dropped.
- **A survey trigger's `neq` condition is no longer inverted**; `in` and `not_in` are implemented.
- **A review request spends quota only when the prompt is actually requested**. With no
  active window scene it used to count, and report, a prompt StoreKit was never asked for.
- **A survey skipped for its love-score or minimum-sessions rule says so** in the debug log.

**Identity, targeting & config**

- **`identify` no longer crashes on a non-JSON trait**. A `LocationData`
  trait is sent as its answer map; any other non-JSON value is dropped with a warning. A `nil`
  trait is kept as JSON null, and `{{user.x | fallback}}` takes its fallback for it.
- **An audience operator the SDK does not implement matches nobody**. It used to match
  every user. `not_exists` is implemented.
- **One wrongly-typed field no longer drops a whole flow, paywall or survey**. The
  field is ignored and reported, and the rest renders.
- **A colour the SDK cannot parse is transparent**. A six-letter CSS name such as `orange`
  drew opaque black.
- **A deferred deep link survives a failed first lookup**. A launch with no network used to
  lose the link for good; up to four failed attempts are retried on later launches.
- **The SDK advertises only gzip**. It also offered `deflate`, which it cannot decode.

### Removed

- **Inert config fields**: `PaywallConfig`'s `affectsPrice`, `ContentBlock.justify`,
  and the Lottie `lottie_json` / `color_overrides` keys. None of them was drawn; use `lottie_url`
  and `row_distribution`. A published document that still carries them decodes as before.
