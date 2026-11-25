# Changelog

All notable changes to the AppDNA iOS SDK are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- A next-step rule whose target is a step of the same flow now goes to that step when the step's id begins with
  `screen_`, which is how the Console names the steps it creates. Such a rule used to be read as a Screens target,
  so the flow ended instead of moving on and the button looked as if it did nothing. A target that names no step of
  the flow still routes to its flow-graph node. See [Onboarding](https://docs.appdna.ai/sdks/ios/onboarding).
  Shared fixtures `step_advance/rule_target_step_id_with_screen_prefix` and `…_object_condition`.

## [1.0.91] — 2026-11-25

### Fixed
- A plan's `{{savings_percent}}` no longer overstates the saving when an authored price writes its currency in letters
  between the amount and its unit (`"25,00 zł per month"` on an annual plan against `"29,99 zł per month"` now reads 16%,
  not 93%). The unit after the amount skips a 1–3 letter currency the way it already skipped a currency symbol. See
  [Paywalls](https://docs.appdna.ai/sdks/ios/paywall). Shared fixture `billing/plan_savings_percent`.

### Changed
- Distribution: Swift Package Manager only. Nothing is published to CocoaPods Trunk any more (it is read-only from
  2 December 2026; 1.0.89 is the last version there, and 1.0.90 was never uploaded). CocoaPods apps install the
  release from its git tag:
  `pod 'AppDNASDK', :git => 'https://github.com/appdna-ai-inc/appdna-sdk-ios.git', :tag => 'vX.Y.Z'`
  (and the same for `AppDNANotificationExtension`). See
  [Installation](https://docs.appdna.ai/sdks/ios/installation#cocoapods).

## [1.0.90] — 2026-11-23

### Fixed
- A plan's badge is drawn in the `pill_selector`, `segmented_toggle` and `product_as_cta` plan layouts, with the same
  badge styling as a plan card. `pill_selector` draws it inside the pill under the price. `segmented_toggle` draws it
  centred above its segment. `product_as_cta` draws it on the button's top edge at `badge_position` (`inline`: under the
  plan name). A blank badge draws nothing. Before this, iOS drew no badge in any of the three layouts. See
  [Paywalls](https://docs.appdna.ai/sdks/ios/paywall). Shared fixtures `dto_parsing/paywall_plan_badge_*`.

## [1.0.89] — 2026-11-22

### Added
- In-app messages honour segment targeting. A message's `audience` (`segments`: shown only to people in at least one;
  `exclude_segments`: never shown to people in any) is checked against the current user's membership, which the SDK asks
  AppDNA for (`POST /api/v1/sdk/segments`, only when a message uses segments) when the configuration loads, when
  `identify` changes the user and after `reset`. The answer is kept for that user only and stored for the next launch.
  Until it has arrived, a message with segments is not shown; a message with no segments is shown as before. See
  [In-app messages](https://docs.appdna.ai/sdks/ios/in-app-messages). Shared fixture
  `audience_eval/message_audience_segments`.

### Fixed
- A `{{savings_percent}}` badge on a plan whose authored price is a per-month figure (`"$5.00/mo, billed yearly"` on
  an annual plan) states the real saving. The amount is read over the unit written right after it (`/mo`, `a week`,
  `per year`) before the plan's other words, so a $5.00/mo annual plan against a $19.99/mo monthly one reads "save 74%",
  not "save 97%". Shared fixture `billing/plan_savings_percent`.

## [1.0.88] — 2026-11-21

### Added
- In-app messages and surveys honour audience rules. A message's or survey's `audience_rules` (the same shape as an
  onboarding flow's or a paywall's: user traits, and `attribution.<field>` / `attribution.param.<key>` keys over the
  stored install attribution) decide whether it triggers for this user; a message or survey with no rules is shown to
  everyone, as before. With no attribution stored, an attribution rule does not match (except `not_exists`).
  `surveys.present(placement:)` now orders the surveys on a name like onboarding flows (higher audience priority, then a
  targeted survey before a catch-all, then lowest id) and skips one whose rules do not match. See
  [Target content by acquisition source](https://docs.appdna.ai/sdks/ios/api-reference#target-content-by-acquisition-source).
  Shared fixtures `audience_eval/message_audience_attribution_network`, `audience_eval/survey_audience_attribution_param`,
  `audience_eval/content_audience_trait_or_attribution`.
- `AppDNA.setAttribution(_:)` and `AppDNA.waitForAttribution(timeoutMs:_:)`: hand AppDNA the attribution your MMP's
  on-device callback delivers, and audience rules on onboarding flows, paywalls and experiments can target any
  acquisition field (`attribution.<field>`, `attribution.param.<key>`, with `starts_with`) on the first launch. Stored on
  the device and sent as the `attribution_set` event. Onboarding selection now evaluates audience rules for a user with
  no traits when attribution is stored. See
  [Target content by acquisition source](https://docs.appdna.ai/sdks/ios/api-reference#target-content-by-acquisition-source).
- `AppDNA.anonymousId`: the anonymous ID AppDNA keys this install's events by. Pass it to your mobile measurement
  partner (AppsFlyer, Adjust, Singular) as its customer user ID before the MMP starts, so AppDNA can join each install
  and its campaign to the person. Stable for the life of the install (it survives restarts, `identify` and `reset()`)
  and readable before `configure` finishes. See
  [Mobile measurement partners](https://docs.appdna.ai/sdks/ios/api-reference#mobile-measurement-partners). Shared
  fixtures `identity/anonymous_id_*`.

### Fixed
- Audience rules: `gte` and `lte` no longer match a user who has no value for the trait, or a value that is not a number. A paywall or onboarding flow targeted at `seat_count gte 10` was shown to every user who never sent `seat_count`. `gt`, `gte`, `lt` and `lte` now match only when both the trait and the rule value are numbers (a numeric string such as `"10"` still counts). Shared fixtures `audience_eval/gte_fails_closed_for_absent_trait`, `lte_fails_closed_for_non_numeric_trait`, `gte_lte_match_at_the_boundary`.
- **Published screens and flows reach the device.** `showScreen`, `showFlow`, screen slots, navigation
  interceptions and screen triggers used to end in `screen_not_found` unless the host had called `previewScreen`
  first: the SDK read the screen index but never the screens in it. The config load now loads every screen and flow
  the index lists (including slot and interception screens), and a cache miss fetches that one screen, or the flow
  and its screens, before giving up. Shared fixture `dto_parsing/screen_served_document`.
- **Screen triggers run on both platforms, and their caps survive a restart.** No tracked event ever reached the
  screen triggers, so a screen authored with a trigger never presented itself. Every tracked event (yours and the
  SDK's own) now runs them after in-app messages and surveys, and a host screen appearing runs the `on_screen` ones.
  iOS now evaluates session count, days since install, on-screen and user-trait triggers as Android does. Max
  impressions and cooldowns are kept on the device. Shared fixtures
  `event_emission/sdk_events_reach_message_and_survey_triggers` and `trigger_hold_is_bounded`.
- **What a user enters on a screen reaches your app.** Values typed or picked in a screen's content blocks stayed in
  the view, so `onScreenDismissed` and `onFlowCompleted` got empty `responses`. They are now keyed by the block's
  field ID, and a flow's navigation rules can branch on them.
- **A long survey question scrolls inside a bottom sheet.** At the sheet's first (half) height, a choice question with
  five or more options had its text cut to one line and its progress bar pushed above the sheet, and nothing scrolled.
  The question now scrolls inside the survey; its text wraps in full, and the progress bar, Back, Next and "Not now"
  stay on screen. A short question stays centred.

### Fixed
- A date answer drawn through `{{responses.<step>.<field>}}` (a `date_wheel_picker` or `input_date` in `date` mode, or
  a form step's `date` field) now shows in the phone's locale, medium date style (`Mar 15, 1990`, `15.03.1990`), the
  same day in every time zone. It used to show as stored (`1990-03-15`). The stored value, and what reaches your app,
  hooks and webhooks, stays `yyyy-MM-dd`. Shared fixture `template_engine/date_answer_draws_in_device_locale`.

## [1.0.87] — 2026-11-19

### Added
- Every onboarding flow, paywall, in-app message and survey event now carries `content_version`, the version of the
  content on screen, and `content_source_id` while the item shows another item's content (Serve instead). Purchases
  started from a paywall carry the paywall's two properties. Both keys are reserved: values supplied through
  `PaywallContext.customData` or other app properties under either name are dropped. See
  [Content properties](https://docs.appdna.ai/api-reference/auto-tracked-events#content-properties-which-content-was-on-screen).

## [1.0.86] — 2026-11-17

### Added

- **A plan badge can be a gradient.** `badge_gradient` on the `plans` section (`{ type, angle, stops: [{ color,
  position }] }`, the `cta_gradient` shape) fills every plan badge with a linear gradient when it has two or more
  coloured stops; otherwise the badge keeps the solid `badge_bg_color`, then the brand accent. `angle` is CSS degrees
  (default 90, left to right). Shared fixture `dto_parsing/paywall_badge_fill`.

- **A text input can be checked by your app while the user types (`onValidateInput`).** Turn on "Check with your app"
  on a Text, Email, Phone, Number or URL input in the console, and the SDK calls
  `AppDNAOnboardingDelegate.onValidateInput(flowId:stepId:fieldId:value:) async -> InputValidationResult?` after the
  field's debounce (600 ms by default) or on return / leaving the field. Answer `.valid(message:)` or
  `.invalid(message:)`; the field draws a green or red border with the message. A newer value cancels the check in
  flight, a late reply is discarded, and no answer within the field's timeout (5 s by default) means "no answer". An
  invalid value blocks Continue; a tap while a check runs waits for the answer; with no answer the user continues
  unless the author chose "Block until it's checked". Offline, the field says so and checks again when the connection
  returns. An app that does not implement the hook gets a plain text input and one warning per field. Each check tracks
  `input_validation_result` (never the value). New `field_style` keys `valid_border_color`, `checking_border_color`,
  `valid_text_color`. For wrapper bridges, `InputValidationResult.decodeBridgeReply(_:)` and `bridgeTimeout`.

- **A Select or segmented question can start with an answer chosen by the author.** `field_config.default_value` on
  an `input_select` (single or multi, every display style) or an `input_segmented` names the option(s) drawn selected
  when the question shows. The default is written as the answer at that moment, as a tap writes it, so a required
  question with a default lets the user continue at once and a summary tile draws the option's label. A restored or
  host-set answer wins over it, a value that names no option is ignored, a number is read as its string, and a
  multi-select keeps the default's order and `max_selections`. Without a default nothing changes.

### Changed

- **A stack child's width is honoured.** A child of a `stack` with an `element_width` (a percentage of the stack, `px` or
  a bare number) is drawn at that width and placed by the stack's alignment, as the console preview draws it; it was drawn
  full width. Flows published with `settings.placement_rules: 2` only.

- **A block with no horizontal alignment that is narrower than its row is centred everywhere, and Android and the
  console preview now draw it where iOS does.** iOS already centred such a block in its column. Two iOS cases change:
  a top or centre zone whose blocks all hug their content sat at the leading edge and is now centred, and an unaligned
  `badge` is centred again (an earlier change on this unreleased version had moved it to the leading edge). The zone
  change applies only to flows the console has published with `settings.placement_rules: 2`; a flow published before
  keeps its placement until it is published again.

- **The first-launch deferred-link check no longer makes iOS ask "Allow Paste?" for text that is not a link.** It
  read the pasteboard on every first launch, so a user who had copied anything in another app saw a paste prompt, and
  the read blocked its thread until they answered. It now reads only when iOS reports, without asking, that the
  pasteboard holds a web link (`detectPatterns`, `.probableWebURL`), and it reads off the main thread. The visitor id is
  taken from a link carrying `appdna_visitor` (`https://yourapp.com/install?appdna_visitor=<id>`) and only that link is
  cleared. The older `appdna:visitor:<id>` text is not a web link to iOS, so iOS no longer reads it; a web page should
  copy the URL form.

- **Every date picker works in the app's time zone, a date-only one too.** A `date_wheel_picker` or `input_date` in
  `date` mode, its calendar, and a form step's `date` field number their days in the time zone set for the app in the
  console (UTC unless changed), as the time and date-and-time pickers already did. So the day a picker opens on,
  `today` and offsets such as `-18y` in `default_date_value` / `min_date` / `max_date`, and the "today" that
  `allow_past: false` / `allow_future: false` compare against are the app's, not the phone's; near midnight they named
  different days. A form step's `time` and `datetime` fields now store the shapes every other time answer stores, the
  wall time in the app's zone with its offset (`23:03:00+09:00`, `2026-11-15T23:03:00+09:00`); they stored `HH:mm` and
  `yyyy-MM-ddTHH:mm:00` with no zone. A time picker with nothing picked yet opens on the current time in the app's zone.

- **Buying a plan the user already owns completes the paywall, as on Android.** A re-buy of an owned subscription or
  non-consumable now calls `onPaywallPurchaseCompleted`, so a host that closes its paywall there closes it; before,
  the paywall stayed open and nothing happened. Revenue is unchanged: it still emits `purchase_restored` (reason
  `item_already_owned`), not `purchase_completed`, and the billing delegate's `onPurchaseCompleted` stays silent.

- **A date-and-time or time wheel with no default opens at 12:00 on both platforms.** With nothing saved and no
  `default_date_value`, the wheel opens on today at noon in the app's time zone. iOS meant noon but took it in the
  phone's zone and drew it in the app's, so it could open on another hour (20:00 for a phone in California with
  the default UTC app zone); Android opened at 00:00. Nothing is stored until the wheel is moved, as before.

- **An image with no description is decorative, and screen readers skip it.** An onboarding image block, a
  paywall image section or a screen image section whose Alt text is blank or unset is now hidden from VoiceOver
  (it was announced as "Image", or with no description); one with Alt text is read as that text, as an image. An
  in-app message's image and a survey question's image have no description field, so they are always skipped.

- **On a wide window, a surface is a centred column, and a landscape iPad splits it in two.** Onboarding steps,
  paywalls, full-screen messages and surveys lay out in a centred column at most 560 points wide, with the background
  still filling the window; a phone in portrait is unchanged. On a regular-width window that is wider than tall and at
  least 720 points wide, an onboarding step shows its visual beside the content and pinned button, a paywall shows its
  pitch beside its plans and pinned zone, and a full-screen message shows its hero beside its copy. Resizing the window
  (Split View, Stage Manager, rotation) keeps the step, the answers and the selected plan.

- **A required segmented question starts with nothing selected.** An `input_segmented` with `field_required: true`
  no longer preselects its first option, so Continue waits until the user picks one. An optional one still starts on
  its first option, and an author-set `default_value` is drawn selected either way.

### Fixed

- **A paywall comparison table draws the styling the console sets, and reads on a dark paywall.** The header row was a
  fixed `#F9FAFB` while its text followed the page, so on a dark paywall the column headers were white on near-white.
  The header row is now the page's text colour at 6% unless `header_bg_color` is set, and the section reads
  `header_text_color`, `header_font_size`, `header_font_weight`, `cell_text_color`, `cell_font_size`,
  `cell_font_weight`, `border_radius` (`corner_radius` wins), `row_alt_bg_color` (striped rows), `feature_header`
  (the top-left header, empty unless named) and a column's own `table_columns[].color` (its header and ticks). A row
  with fewer values than columns keeps its cells under their headers. Shared fixture
  `dto_parsing/paywall_comparison_table_style`.

- **A block with a percentage width is drawn when it is the only block in its zone.** A 60%-wide button alone in
  the pinned zone (or any block with an `element_width` under 100% with no full-width sibling) was a fraction of its
  own width rather than of the zone, so it shrank on each layout pass until it was not drawn at all. It is now that
  fraction of the zone, as on Android and in the console preview.

- **A surface no longer narrows itself as it opens on a wide window.** An onboarding step, a paywall, a survey or a
  full-screen message on a window wider than the 560-point column could open at the window's width and shrink to the
  column over about half a second, because the first measurement of the window landed in an animated transaction. The
  column is now applied without animation, so the first frame drawn is the final one. Phones in portrait are unaffected.

- **A link inside a step sheet opens in the in-app browser,** as a link on the step does; it opened Safari and left the app.

- **A consent ticks from its words, not only its box.** A tap anywhere on an Agreement consent's text ticks or unticks it,
  as the 22-point box does; a link inside the text still opens the link and does not tick. On a step and inside a step's
  sheet alike.

- **A long segmented answer wraps to two lines instead of being cut to one.** An `input_segmented` drew every label on
  one line, shrunk to 80% and then cut with an ellipsis, so on a phone the answers of a quiz could not be read. A label
  now wraps to at most two lines, centred, every segment is as tall as the tallest, and a label longer than two lines is
  cut there. The console warns when an answer will not fit in two lines.

- **A bare-number `element_width` / `element_height` is points, as the console preview draws it.** A width written
  without a unit as a JSON number (`120`) was dropped by the decoder, so the block filled its row; a string `"120"` was
  drawn, but its `horizontal_align` had no box to act in. Both forms are now 120 points, and an aligned block with a
  bare-number width is placed by its alignment, as one with `120px` is.

- **A rule on a later step that reads an earlier step's consent now matches.** A multi-consent Agreement answers each
  consent under `<field_id>.<consent_id>`, so a later step addresses it as `<step_id>.<field_id>.<consent_id>`. The
  key was split at its last dot, which named no step, so the rule never matched and the flow fell through to the next
  step in order. Every dot is now tried, last first; keys that matched before match the same way.

- **A text input draws its focused and error border colours.** A single-line text input (`input_text`, `input_email`,
  `input_phone`, `input_number`, `input_url`) stroked `field_style.border_color` in every state, so the console's
  Focused Border and Error Border colours did nothing. It now strokes `error_border_color` while the field is in error,
  else `focused_border_color` while it has the keyboard, else `border_color`, the same rule as Android. Nothing puts a
  text input in error yet; the error colour applies once a setting does.

- **A "link" button inside an option's bottom sheet opens its link.** It did nothing on iOS, while Android opened it.
  A `link` button in an option's `sheet_blocks` now opens its URL in the in-app browser and keeps the sheet open, as a
  `link` button on a step does. The URL is scheme-checked first. The "Add widget" how-to sheet still opens nothing.

- **"Maybe later" on a permission step no longer raises the OS permission prompt.** On a `permission` step that has a
  button with the `permission` action, a second button authored as `next` (a "Maybe later" or "Not now") ran the
  permission request too, so the user who declined saw the OS sheet anyway, and on iOS the app's one notification ask
  was spent on them. A `next` button now asks only when the step has no `permission` button, which is the case of a
  step whose one CTA was authored as `next`. When the step has a `permission` button, `next` advances without asking
  and records no `permission_<type>` outcome. A `permission` button inside a Multi-buttons, row or stack counts too.

- **A badge with no alignment sits at the leading edge, as on Android and in the console preview.** A top-level
  `badge` block with neither `horizontal_align` nor `vertical_align` was centred in the step's column, with or without
  an entrance animation, while Android and the console preview put it on the left. It now sits at the leading edge.
  A badge with an authored `horizontal_align` is placed as before.

- **Every icon the console offers draws.** Material `shopping_cart`, `account_circle` and `done` had no SF Symbol and drew a
  question mark. A Lucide component name (`CheckCircle`) is now read as `check-circle`, so a mapped icon saved in that
  form draws too.

- **Text inputs are named for VoiceOver and TalkBack.** A text, number, email, phone, URL, password, textarea or
  location input, as a content block or a form step's field, now carries its label (else its placeholder) as its
  accessibility name. The label was drawn as a separate text above the field, so a screen reader landed on an unnamed
  text field, and UI automation could not find the field by name.

- **A required field's asterisk trails its label when the label wraps.** The `*` was drawn beside the label, so a
  label on two lines left it at the edge of the row next to the first line. It is now part of the label's text, on
  content-block fields and on the legacy form step's fields, on both platforms.

- **The selected segment of `input_segmented` draws its authored colour.** iOS drew the system grey pill whatever
  was authored, because a segmented `Picker` ignores `.tint`. The control is now drawn by the SDK, as on Android:
  the selected segment takes `field_style.fill_color`, else `active_color`, else the brand accent, and its label
  contrasts with a light fill on both platforms.

- **A chip is as wide as its label, on one line.** `input_chips` laid its chips out on iOS in an adaptive grid where
  every chip got an equal cell, so a label longer than the cell wrapped inside its chip, sometimes mid-word. Chips now
  hug their labels and flow onto the next row, as on Android; a label wider than the whole row truncates on one line.

- **`survey_question_answered` is sent once per question, not once per keystroke.** A typed answer is sent when the user
  moves on with Next or Submit, with the full text (not if it is blank); a tap answer (NPS, choice, rating, …) is sent
  when it is picked, as before, and an answer the same as the one already sent is not sent again. A typed answer sent
  one event per character, so per-question analytics counted partial strings as answers.

- **A screen's or survey's unstyled text follows its own background, not the phone's appearance.** A screen with a
  white background drew its unstyled text (and a section's, on the section's own fill) in the phone's appearance, so
  in dark mode it was white on white; a white survey lost its question and its "Yes" label the same way. Default text
  and system controls now resolve against the authored background — dark ink on a light one, light ink on a dark,
  gradient or image one — and follow the phone only when no background is authored. Authored colours still win.

- **Server-driven screens draw their sections.** The section renderers were registered only in tests, so every
  screen, slot and preview drew its background and close button and nothing else. They are now registered the first
  time a screen renders.

- **The `animated_loading` spinner takes the block's colour.** The spinner of a checklist or circular loader was drawn
  in the system tint, so it could vanish on a light step in dark mode. It now uses `progress_color`, then
  `accent_color`, then the app's brand accent — the same colour Android uses.

- **A hand-off to your own billing provider shows no "Payment failed" banner.** Under a provider that owns purchases
  (Adapty, or RevenueCat when its SDK is not linked) a paywall tap reports `providerNotAvailable` so your app can buy
  with the provider. With no `post_purchase.on_failure` authored, the paywall now shows nothing for it, as for a
  cancel; an authored `on_failure` still runs. Every other failed purchase still shows the default banner. Shared
  fixtures `billing/paywall_failure_default_by_error_type` and `billing/paywall_failure_provider_handoff_is_silent`.

- **Every card plan layout shows which plan is selected with a circle.** `mini_cards`, `single_hero` and
  `carousel_cards` drew no selection circle; they now draw a filled check on the selected card and an empty ring on the
  others, at the card's top trailing corner, as `grid`, `horizontal_scroll` and the vertical stack already did, and as
  Android draws them.

- **The trial badge, a plan's trial line and its feature checks match the paywall's own colours.** With no colour
  of their own they were drawn in the brand accent, or indigo when none is set, whatever the paywall's theme. They now
  take the paywall's accent: the CTA's authored colour (`cta.style.bg_color`, then `cta.bg_color`), then the brand
  accent. The social-proof trial badge also honours its own `badge_color` (the console's "Badge Color"), which was
  ignored. Shared fixture `dto_parsing/paywall_trial_badge_color`.

- **A failed purchase always tells the user.** A paywall with no `post_purchase.on_failure` showed nothing when a
  purchase failed (a product the store does not have, a declined card, a store outage): the button simply became
  tappable again. It now shows the error banner, "Payment failed. Please try again.", as `show_error` does. A
  cancelled or pending purchase stays silent. An authored `on_failure` is unchanged.

- **A generated message's or paywall's animation and video play on both platforms.** An in-app modal draws a
  video hero (`video_url`), muted and looping with no controls, as the full-screen message and Android already did;
  before, it skipped to the image. A paywall `video` / `video_background` section honours `video_autoplay` and
  `video_loop` (it always waited for a tap) and shows no player controls when it autoplays. A blank `lottie_url`,
  `rive_url` or `video_url` on a message hero, or a blank URL on a paywall animation or video section, is no media:
  the next hero draws, or the section draws nothing. Shared fixtures `dto_parsing/message_hero_media` and
  `paywall_media_section_playback`.

- **When several served experiments name one paywall, flow, message or survey, the same one decides on every launch,
  and on both platforms.** The surface resolver walked the served experiments in dictionary order, which Swift
  randomises per process, so with a served config that had diverged from the rows (an experiment whose removal never
  landed, still listed as running) the arm a user saw could change between launches, and iOS and Android could draw
  different experiments. They are now tried most recently started first (`started_at_ms`), ties by experiment id; the
  first one the user is in decides. Shared fixtures `experiment_serving/several_experiments_on_one_entity_*`.

- **An onboarding step's options are reachable by UI tests and VoiceOver.** An invisible helper view behind every
  scrolling onboarding step was the size of the whole step, and the accessibility tree showed it as an empty element
  over the step's content. Touch was not affected, but XCUITest reported a list Select's options as not hittable,
  and a test or VoiceOver user exploring by touch could land on the empty element instead of an option. The helper
  is now a single point, hidden from accessibility.

- **A push image URL that answers an error no longer shows as a broken attachment.** The Notification Service
  Extension attached whatever body the image download returned, so an expired link's 403 page or a 404 was attached as
  the image. Only a successful response whose body is an image or video is attached now; otherwise the push shows as
  text, as on Android. Redirects are still followed.

- **A queued event batch is deleted only when the server refuses its content.** An event upload answered 401, 403,
  404 or with any other 4xx (except 408 and 429) used to delete its batch from memory and disk and count it as dropped,
  so an outage behind a tunnel or proxy that answered 401 lost every event queued during it. Now a batch is dropped,
  and counted, only on a 400, 413 or 422 that carries the AppDNA API's JSON error body. A 401 or 403 keeps the events
  and pauses uploads until the next foreground or `AppDNA.flush()`; a 404, 409, or an answer that is not the API's own
  (an HTML page from a tunnel, captive portal, proxy or load balancer, whatever its status) keeps them and retries. The consent signal follows the same rule: a 401 / 403 / 404 or a
  proxy's page is retried instead of dropping the signal until the next launch.

- **A paywall `text_style` that sets only some fields keeps the element's own typography.** A style that set only a
  colour (as the server's contrast pass writes) replaced the element's default font with the 16pt body font, so a
  header title drew at body size. A style now changes only the fields it sets, at every paywall text element, as on
  Android; a style without a colour keeps the element's default colour, and one without an alignment keeps its
  alignment.

- **An onboarding list's or a survey's colour-only text style keeps the default size.** A list `style` or a
  survey `question_text_style` that set only a colour redrew the list items, and a survey's answer options, at 16pt
  instead of the 17pt body size, and the survey theme's font and size were lost. A style now changes only the fields
  it sets there too.

- **An in-app message triggered while the app is in the background is shown when the user opens the app.** A background launch (a silent push, a background fetch) tracks events such as `session_start`, and a message triggered by one was drawn into the scene that launch connects in the background: it counted as shown, `in_app_message_shown` was tracked and a `once` message was used up, while nobody could see it. Only a scene in the foreground is drawn in now. A message triggered with none is held, not counted, and shown the next time the app becomes active, if it is still published, inside its dates and allowed by its frequency. It is shown once however often it triggered, and several held messages are shown one at a time in trigger order.

- **A journey's in-app message delivered during a background launch is shown when the user opens the app.** When the app was running in the background with no window (woken by a push or a background task), the SDK tried to show a message a journey sent for about 10 seconds, then stopped. The message stayed unshown until the app was next launched from cold. It is now shown the next time the app becomes active, unless it has expired, and it is still shown only once.

- **A journey's in-app message is no longer drawn while the app is in the background.** A background launch (a silent push, a background fetch) can connect a scene with a window while the app is not on screen. The SDK drew a waiting message there at once, marked it shown and counted `in_app_message_shown` while the user was not looking; if the system then ended the app before the user opened it, the message was never seen and not sent again. Only a scene in the foreground is used now. A message that arrives during a background launch is shown when the user opens the app, as on Android.

- **A journey's in-app messages reach users who have not signed in.** The SDK listened for messages a journey sends only after `identify`, so a journey's "Send in-app message" step to an anonymous user was counted as sent and never shown. The SDK now listens from `configure` on the device's anonymous ID; after `identify` on the anonymous ID and the user ID (a journey that started before sign-in keeps sending to the anonymous ID); after `reset()` on the anonymous ID again. A message that arrives while another is on screen is shown when that one closes, a message that cannot be drawn yet (no window at a cold launch) is retried, and a message is never shown twice.

- **`identify` and `reset` called right after `configure()` are applied.** `configure()` returns at once and builds the SDK in the background, and an `identify` (or `reset`) called before that build had run did nothing: no user id was stored, no `identify` event was sent, and nothing was logged, so restoring the signed-in user at launch ran the session as anonymous. Such calls are now held and applied, in the order they were made, as soon as the SDK has configured; an event tracked after the `identify` carries the user. The same holds for `setPushToken`, `setPushPermission`, `trackPushDelivered`, `trackPushTapped` and `reportPayingUser`. An `identify` made before `configure()` still does not store the user id (there is no identity yet, as on Android), and now logs a warning.

- **A day can be picked on the Calendar style inside an onboarding step.** A Date Picker in its Calendar style (`picker_variant: graphical`, the default for a date) and an inline Date or Date-and-time field with the Calendar variant drew the system calendar, whose day cells took no tap inside a step: only its month arrows and year header worked. The calendar is now drawn by the SDK — the same month grid the range calendar uses, with the month and year header opening a list of years — and a tapped day is stored (a date and time keeps its time of day, set from a time field under the grid). VoiceOver can pick a day too.

- **The Date Picker draws the style chosen in the console.** `field_config.picker_variant` (`graphical` · `wheel` · `compact`) decides what a `date_wheel_picker` draws; unset, a date is the calendar and a date-and-time or a year the wheel. A **Date** field (`input_date` / `input_datetime`) with `picker_presentation: inline` — the console's default — always drew the calendar, so its Picker Variant changed nothing: it now draws the variant chosen.

- **Every colour of a measurement wheel picker can be set.** The `wheel` and `dial` styles drew their band, the value on the band and the rows around it from the ruler's keys, and the unit label, the field label and both unit-toggle labels in colours no key reached. Each part now has its own `field_config` key: `band_color`, `band_text_color`, `row_text_color`, `unit_color`, `label_color`, `toggle_active_text_color` and `toggle_text_color`, beside the existing `needle_color`, `tick_color`, `track_color` and `toggle_active_color`. Unset keys draw what was drawn before.

- **In-app messages and surveys trigger on the SDK's own events.** A message or survey whose trigger is an event the SDK tracks itself (`app_open`, which is the console's default message trigger, `session_start`, `onboarding_flow_completed`, the purchase events, and the others on the auto-tracked events page) never appeared: only events passed to `track()` were checked against triggers. Every tracked event is now checked once, message first. Events tracked before the SDK has its config, such as `app_open` on a cold launch, are held (up to 32) and checked once the config is ready; a config cached from an earlier launch, or bundled in the app, is used at once. A message never triggers on the `in_app_message_*` events and a survey never triggers on the `survey_*` events, so showing one cannot show another of the same kind.

- **A paywall's pinned plans and button sit on the paywall's own colour.** The pinned zone at the bottom of a paywall
  had no background, so the scrolling body showed through it: feature rows could be seen between the plan tiles and
  inside an unselected one. The pinned zone now paints the page's colour, or a gradient's end stop; a paywall with an
  image or video background is unchanged. Android already laid the body out above the pinned zone.

- **A select answer drawn in text shows the option's label, not its stored value.** A `{{responses.…}}`,
  `{{onboarding.<step>.<field>}}`, step or input token that names a Select, Segmented or chips answer now draws the
  picked option's label (a multi-select: the picked labels, comma-joined), where it drew the option id or the
  token's fallback. This holds for an answer with no tap behind it (a resumed flow, a default, a host-set answer), on a
  later launch's paywall, message or screen, and when two steps share a field id (each answer draws its own step's
  option). A stored value, a URL and a hook's headers keep the option id.

- **A list on its own card draws the card across the row.** A `list` with an `element_width` and a `block_style` card
  hugged its longest row, so its card was narrower than the copy above it while the console preview drew it full width.
  A list with an authored width now fills that width before its card is drawn; an unsized list still hugs.

- **One tap on a button moves a tap-anywhere step once.** On a step with `tap_anywhere_advances: true`, a tap on a
  button ran the button's action and the tap-anywhere advance, so the user skipped the next step. A tap a control
  handles now acts only as that control, as on Android.

- **A date or time field is readable in any appearance.** The sheet a compact date or time field opens drew its wheel
  in Light while the sheet followed the phone, so in Dark the date being chosen was black on a dark sheet; the sheet,
  its wheel and its Done button now take one appearance (the authored `color_scheme`, or a light `text_color`, else the
  phone's). An unstyled date or time value on the step takes its ink from its own fill, else from what is behind it; it
  could be black on a dark step. An authored text colour still wins.

- **A summary tile keeps its words whole, and a row of tiles shares one height.** A word wider than its tile broke
  mid-word. A tile's value now shrinks until its longest word fits (down to half size) and wraps between words, and
  every tile in a row is as tall as the tallest.

- **A paywall with no background draws a readable header.** With no authored background the paywall is drawn on the
  system background, but its header text was judged against white, so it could be white on a light page. The header now
  reads the page the paywall really paints.

- **Unstyled controls follow the step's background, not the phone's appearance.** Option labels, segmented controls,
  chips and other unstyled parts of a step took the phone's appearance while the step's background was authored, so a
  light step on a phone in Dark drew white labels on white. Each block now takes its appearance from what is drawn
  behind it; an option or dropdown with its own fill is judged by that fill, a sheet keeps the phone's appearance, and
  authored colours still win. Steps built without content blocks (the older step types) follow the same rule.

- **The close control and Skip read on a light step in Dark.** An unstyled close (X) and Skip followed the phone's
  appearance and drew pale grey on a white step when the phone was in Dark. They now use a fixed colour for a light
  step; an authored `icon_color` still wins.

- **A rule on a number answer matches however the number was written.** A rating answer is stored as a number, a
  published rule value of `4` is read as a whole number, and the console can write `"4"`; they were compared by type, so
  a 4-star answer fell to the fallback rule. Next-step rules, block visibility, form dependencies, a survey's `show_if`
  and event conditions on surveys and messages now compare numbers by value. Two pieces of text still compare exactly.

- **An in-app message draws its authored font and sizes.** `font_family`, `title_font_size` and `body_font_size` were
  dropped before the message was drawn, so every message used the default type. They are now applied, as on Android.

- **A step the user has scrolled stays where they put it.** On a step that scrolls to keep a location field's provider
  logo in view, a scroll the SDK asked for just before the user's drag could land after it on a slow device and take
  the step back. A move that lands within a second of the user's drag, away from where they left the step, is undone.

### Added

- **Sheets inside a step.** A step's `sheets` slide up over it, opened by an `open_sheet` button or by Continue when
  a required answer it is missing is in a sheet (then no "Please fill in" message; the sheet's `next` re-runs Continue).
  A sheet's inputs are the step's answers, live, and the step's gate counts them; a swipe or a scrim tap closes it
  without declining anything. Drawn in the step's own hierarchy, not `.sheet`. Events `onboarding_sheet_opened` and
  `onboarding_sheet_closed`. `close_sheet` closes it from inside.

- **Social Login draws Meta's official Facebook mark.** The `facebook` provider drew a bold letter "f". It now draws the
  Facebook logo from Meta's brand asset pack, unmodified: the blue mark on a light, outlined or minimal button, and the
  white mark on a dark fill (the default Facebook fill is dark). `icon_style: monochrome_light` gives the white mark and
  `monochrome_dark` the blue one, because Meta allows the logo only in Facebook Blue or white. It is drawn at 20 points
  with half a logo's width of clear space to the label. Provenance is in NOTICE.md.

- **Part of a heading in its own colour, and Justify for headings and rich text.** A `heading` whose text carries a
  `[word](color:EE6885)` run draws that word in that colour, as `rich_text` already did; a heading with no such run
  draws exactly as before. `style.alignment` (heading) and `base_style.alignment` (rich text) accept `justify`, which
  fills every line but the last edge to edge. On iOS a justified block is drawn through UIKit, keeping its bold,
  italic, colour runs and links (which still open in the in-app browser).

- **One Agreement element can hold up to five consents.** With `field_config.consents`, each consent has its own
  text, colours and `required`, drawn one under another. Each answer is stored as its own boolean under
  `<field_id>.<consent_id>`, so rules and `{{responses.*}}` read a consent like any other answer, and each required
  consent gates the CTA until it is checked. An Agreement without `consents` is unchanged.

- **A Share button action.** A button can now open the phone's share sheet (iOS `UIActivityViewController`, Android an
  `ACTION_SEND` chooser) with text and an optional link set in the console: on an onboarding button or a
  Multi-buttons child (`action: "share"`, `share_text`, `share_url`; the step stays), on an in-app message CTA
  (`cta_action: { type: "share", text, url }`; the message closes, then the sheet opens) and on a paywall extra
  button (`action: "share"`, `share_text`, `url`; the paywall stays). Text and link are trimmed; with neither,
  nothing opens. No event is tracked, because Android cannot report whether a share was completed.
- **Push deliveries are confirmed by the device, also while the app is closed.** The Notification Service
  Extension (`AppDNANotificationExtension.NotificationService`) now confirms every AppDNA push to AppDNA: the push
  carries a signed receipt (`receipt_url`, `receipt_sig`), which the extension posts over HTTPS before it hands the
  notification back (at most 8 s). The server sends every push `mutable-content: 1`, so the extension runs for a plain
  push too. With an App Group named under `AppDNAAppGroup` in the Info.plist of the app and the extension, the
  extension also hands each delivery to the app, which tracks `push_delivered` for it once when it next runs.
  `reportsDelivery` (override to `false`) opts out. Without the extension, a push that arrives while the app is closed
  is counted as sent, not delivered.


- **A step that advances by itself can show a countdown.** `auto_advance_indicator` on the step (beside `auto_advance_seconds`): `show` (default false), `style` (`text`, `bar`, `both`), `text` (`{seconds}` = whole seconds left), `text_color`, `font_size`, `bar_color`, `track_color`, `bar_height`, `position` (`top`, `bottom`). The countdown takes its own space above or below the step, so it never covers the heading or a pinned button. Off by default, so published flows are unchanged.

- **An "Add widget" button action.** An onboarding button (top level, or a Multi-buttons or Row child) with `action: "add_widget"` helps the user put the app's own widget on the Home Screen. iOS lets no app add a widget, so the button opens the how-to the author wrote (`howto_blocks_ios`, ordinary content blocks) in a bottom sheet over the step. The step advances when the how-to's Done button is tapped, or by itself when the user comes back from the Home Screen with a new widget placed; closing the sheet any other way returns to the step. The outcome is written into the step's answers as `widget_status`, so `next_step_rules` can branch on it: `added` when a widget of a new kind and size appeared; `not_added` when the user had none of the app's widgets before and none appeared; `unknown` when they already had one and nothing new appeared (WidgetKit reports one entry per widget kind and size, so a second widget of a size already placed cannot be seen), or when the widgets could not be read; `unavailable` when the app ships no WidgetKit extension. New events: `widget_add_tapped`, `widget_howto_shown`, `widget_howto_dismissed`, `widget_added`, `widget_not_added`, `widget_add_unknown`, `widget_add_unavailable`. The SDK now links WidgetKit. Inside a how-to, and inside an option's bottom sheet, a button acts only as Done (`next` / `continue`) or Close (`dismiss`); any other action there does nothing.

- **A Date Picker can pick a range of days.** `field_config.selection_mode: "range"` (date mode) draws a month calendar where two taps pick a range, joined by a bar in `field_config.range_color` (unset: `highlight_color` at 20%). The answer is `<field_id>` = `start/end` (`2026-11-07/2026-11-15`) with `<field_id>_start`, `<field_id>_end` and `<field_id>_days` (both ends included); until both ends are picked `<field_id>` is unset. Tapping the month and year opens a list of years to jump to.

- **A linear style for the measurement wheel picker.** `measurement_style: "linear"` draws a vertical slider on the left, filled from the bottom (the unit's `min`) to the value, with the value and its unit on the right — the simplest height picker. With one unit the unit is locked on screen. A tap or drag picks the value under it, snapped to the unit's step, and the interaction fires when the finger lifts; the slider is adjustable with VoiceOver/TalkBack. Sizes: `linear_height` (240), `track_width` (8), `thumb_size` (28); `thumb_color` defaults to `needle_color`.

- **A button can depend on other elements on its screen.** `field_config.cta_dependencies` lists
  `{ block_id, condition }` entries (`answered`, `all_selected`, `min_selected` with `count`, `correct`, `equals` with
  `value`). Until every one holds the button is inactive (a tap does nothing) and draws in `cta_disabled_bg_color`, or its
  own colour faded; then it draws in `cta_enabled_bg_color` and acts. An entry naming an element not on the step holds.
- **A Select that advances on the pick can ask first.** `field_config.advance_confirm: true` beside `auto_advance` opens
  a dialog (`advance_confirm_text`, default "Are you sure?") before the step moves on; its confirm button
  (`advance_confirm_yes`, default "Yes") advances, and its cancel button (`advance_confirm_no`, default "No") stays with
  the pick kept.
- **A Select can say whether the pick was right.** `field_config.correct_values` marks the correct option(s); once
  the user has answered, `feedback_correct_text` (default "Correct!") in `feedback_correct_color` (default #16A34A) or
  `feedback_wrong_text` (default "Not quite.") in `feedback_wrong_color` (default #DC2626) shows under the options. A
  multi-select is judged once as many options are picked as are marked.
- **`animated_image`: one long image scrolling in a seamless loop.** Set `image_url`, `height` (the visible height; the block fills the width), `corner_radius`, `alt`, and in `field_config` `scroll_direction` (`left`, `right`, `up`, `down`) and `scroll_speed` (points per second, 1–400, default 30). The image fills the block across the scroll direction and repeats along it, so the loop never jumps.

- **A block's background can reach past it on each side.** `field_config.background_bleed_top`, `background_bleed_bottom`, `background_bleed_left` and `background_bleed_right` take `"edge"` (reach the screen edge on that side) or a number of points (up to 400). The block's content stays where it was; only the background moves. Left and right still follow `background_full_bleed`, and an authored value wins over it. Set from the console on Multi-buttons: to the edges for a group at the bottom of a screen, by a set amount for a group in the middle.
- **The SDK tells AppDNA when a user declines analytics.** Declined users' events never leave the device, so the
  server could not honour the decision on messages it sends itself. The SDK now sends one small consent signal
  (`POST /api/v1/ingest/consent`: the device's anonymous ID, the user's ID if known, the decision and a timestamp)
  when the decision is set or changes, when the user changes while analytics is declined, and once at each launch
  while analytics is declined. A failed signal is retried up to three times, then at the next launch; an
  acknowledged one is not sent again. `setConsent` called before `configure()` is now kept and applied when the SDK
  configures. A signal not yet acknowledged at `shutdown()` is not retried after it; it is sent again at the
  next `configure`.

- **A plan's savings figure is computed from the prices drawn.** Write `{{savings_percent}}` in a plan's `badge` or `savings_text` ("Best value – save {{savings_percent}}"). The SDK fills it from the prices the paywall shows (the App Store's once it answers, the authored ones otherwise), per month and rounded down, and hides the text when no figure can be worked out. A typed percentage is drawn as written.

- **Onboarding flows and surveys can be asked for by name.** `presentOnboarding(placement:)` and `surveys.present(placement:)` show the item whose placement matches, set in the console. Several flows can share a name: higher audience priority first, then a targeted flow before a catch-all, then lowest id. `false` when nothing answers the name.

- **The date wheel is drawn by the SDK.** A `date_wheel_picker` wheel's selection band is `highlight_color` at 10% opacity, its columns follow the locale's date order, and `picker_mode: year` answers a single year as four digits. Its rows stay inside the wheel and fade at its top and bottom edges while it scrolls. Calendars the wheel cannot number (for example Japanese eras) keep the system wheel.

- **A stacked option's title can carry links and coloured words.** `label_markdown` on an option draws inline markdown: `[Terms](https://example.com)` is a link in the block's `option_link_color`, `[word](color:EE6885)` colours a word, and `label` stays the stored answer.

### Added

- **A placement can be a name of your own.** A paywall's `placement` may be any name you set in the console, and the app asks for that exact string. When several live paywalls answer one placement they are now tried in a fixed order, the same on every launch: highest priority, then a paywall with audience conditions before one without, then lowest paywall id. Before, a tie went to whichever came first in memory.

- **A navigation rule can route by the button pressed.** A rule that compares the reserved answer key `__button_pressed` to
  a button's id matches the press that left the step. The press is seen only while the rules are evaluated, and never reaches
  the responses, the hook or a webhook.

- **A Select can move the user on when picked.** `auto_advance: true` on an `input_select` advances the step on the pick
  (a multi-select: on the pick that reaches `field_config.max_selections`), through the step's own `next`, so a screen with
  only a Select has a way forward.

- **A toggle's settings.** A standalone `toggle` reads `field_config.toggle_on_color`, `toggle_label_color` and
  `toggle_description_color`, and `toggle_action` names the element interaction your app receives, with `"true"` or
  `"false"`, when the user switches it.

- **A flow-wide background.** `settings.background` on an onboarding flow (the same shape as a step
  background: colour, gradient, image, Lottie or Rive) is drawn by every step that sets no background of
  its own. Before, a step without one drew `systemBackground`, so a theme had to be repeated on every step.

### Fixed

- **`app_open` is tracked on a cold launch too.** It was tracked only when the app returned from the
  background, so a user who opened the app from cold never sent it: journeys and funnels that start or wait on
  `app_open` missed every cold launch. It is now tracked once per foreground entry: on a launch with UI and on
  each return. A scene-based launch that also posts `willEnterForegroundNotification` still sends one, an app
  launched in the background sends it when its UI first appears, and a `shutdown()` and `configure()` inside one
  foreground sends none. No properties, as before. A cold launch no longer rotates the session twice when the
  scene lifecycle also posts the foreground notification.

- **Time and date-and-time answers work in the app's time zone.** Set in the console under Settings → Apps (UTC
  unless changed), it is the zone a `time` or `datetime` wheel shows and takes, and answers are stored with its offset:
  `2026-11-10T15:03:00+01:00`, `15:03:00+01:00`. A drawn `{{responses…}}` shows them as `2026-11-10 15:03` / `15:03`.
  They were UTC instants in the phone's zone; those, and Android's older `HH:mm` shapes, are still read.

- **No faint copy of today's date near a date field.** The hidden picker that warmed UIKit up drew its selected row.

- **Tapping a row of the date wheel selects it.** Only a drag moved the wheel before.

- **The date wheel opens inside its bounds.** With no default and no answer, and today outside `min_date`/`max_date`,
  the band shows the nearest allowed day instead of today's month and day against the first year.

- **The date wheel's other rows read on a dark step.** With no wheel colour authored, the rows above and below the band
  take their ink from the surface behind the block. They drew near-black on a dark step.

- **A date-only `date_wheel_picker` answer is the date on the wheel.** It is stored as `yyyy-MM-dd`, as on Android, in
  every time zone. It was an ISO 8601 instant of local midnight, which east of UTC carried the previous day's date into
  templates, your app and webhooks. An answer saved that way is still read back as the day it was picked.

- **A warning banner draws one background.** `block_style` (the console's Design panel) now styles the banner's card:
  its background, border and corner radius replace the banner's defaults instead of drawing a second layer behind it.

- **An archived, unpublished or deleted flow, paywall or survey stops showing.** After a config fetch, every
  onboarding flow, paywall and survey the server no longer lists is dropped from memory and from the cached
  config, so it does not come back after a restart. An empty list means none are live. A failed fetch
  (offline, an error) removes nothing. Before, a device kept serving every one it had ever fetched.
- **A nested block draws its container style.** `container_bg_color`, `blur_background` and the other
  `container_*` keys of a block inside a row, stack, multi-buttons or section background were not drawn on iOS
  (only top-level blocks got them); Android drew them. Both now resolve them through one shared rule.
- **Push tokens name their user.** The token registration now sends the device's anonymous ID and, once
  `identify` ran, the user ID, and registers again after `identify` and `reset`. The server stored every SDK
  token without a user, so a push to a user, a list or a segment reached no SDK device.
- **A gallery title is readable on a light step.** A `media_gallery` title with no `gallery_title_color` was
  white everywhere; it now follows what is behind the gallery (dark on a light step, white on a dark one).
- **A multi-pick dropdown is readable on a dark step.** Its placeholder, picked labels and chevron were the
  system text colours, near-black on a dark step in a light appearance; they now follow the field's own fill,
  else what is behind it.
- **A row's fill is read through one shared rule.** `field_config.bg_color` at `background_opacity` (clamped to
  0–1, multiplying the colour's own alpha) is resolved the same way on both platforms; no visual change on iOS.
- **Specific colours win over a Typography style.** A selected plan's `selected_text_color` and a plan's own
  `price_color` did nothing when the plans section also styled the name, price, trial or feature text, and a
  survey's `question_text_style` without a colour drew questions in the system text colour instead of the
  theme's `text_color` (dark on a dark survey). The specific colour now reaches the text, as on Android.
- **A styled button's label keeps its colour.** A button with a Typography `style` drew its label in the
  system text colour (near-black in a light appearance) whatever its variant or `text_color` said, so on a
  dark button it was unreadable. The label is now `text_color`, else `style.color`, else the variant's own
  colour (white on a filled button, the button colour on `outline` and `text`), as on Android.
- **An unstyled warning banner is readable on a light step.** A `warning_banner` with no `text_color` drew
  its message and subtitle white on its translucent tint, which on a light step measured about 1.1:1. They
  now take their ink from what is behind the banner (dark `#111827` on a light step, white on a dark one), or
  from the banner's own `bg_color` when it sets one.
- **Option labels and summary headlines are readable on any step.** An unstyled option label in a Select
  (options without their own fill) and a `summary_screen` headline with no `text_color` take their ink from
  what is behind them; before, labels were dark on a dark step and the headline white on a light one.
- **Unstyled rich text and lists are readable on dark screens.** A `rich_text` or `list` block with no colour
  takes its ink from what is behind it, as text does; before, it was dark on a dark step or fill.
- **An unregistered custom view no longer shows its debug key to users.** A `custom_view` block whose
  `view_key` the app has not registered drew the literal `[view_key]` whenever it had no `placeholder_text`.
  A release build now draws the authored placeholder image or text, and nothing when neither is set (the
  missing key is logged); a DEBUG build still shows `[view_key]`.
- **Text on a pale gradient is readable.** Text nobody coloured (headings, text, input labels and typed
  text, the back / close / Skip controls) is drawn dark on a gradient whose every stop is light. It was
  drawn white on every gradient, so on a pale one it disappeared. A gradient with any dark stop keeps
  white text, and Google's logo is unchanged.
- **The paywall guarantee badge draws its shield.** The default symbol was `shield.checkmark.fill`, which
  is not an SF Symbol, so the badge drew no icon at all. It is `checkmark.shield.fill` now, and the old
  spelling is read as that symbol.
- **In-app message buttons open their link.** A CTA's link is read from `cta_action.url` and also from
  `cta_action.value`; the action type `url` reads as `open_url`; and a `cta_action` written as a bare string
  no longer stops the whole message from decoding. Before, a CTA saved as `{type, value}` (the shape the
  console writes) only dismissed the message.
- **Unstyled headings and text inside a container follow the container's fill.** A heading or text with no
  colour inside a dark row or section background is drawn light, as on Android; before, iOS judged it by the
  step behind the container.
- **An imported loading animation draws its variant.** An `animated_loading` block that sets `variant` instead
  of `loading_variant` now draws that variant, as on Android; before, iOS drew the checklist.
- **Text inside a zoned section background is readable.** Unstyled text in a `section_background` takes its ink
  from the zones behind it (one zone: its colour; several: any dark zone means light text). Before, it took the
  step's background, so it could be dark on a dark zone.
- **The rating block stores its answer.** A `rating` block's selection is stored at its `field_id` (else its id),
  so it is a response, a routing input and a required-field value, as on Android; VoiceOver can also set it
  by swiping up or down. Before, iOS kept it on screen only.
- **Multi-buttons no longer draws a button your data hid.** A child the author set to hide when its list is
  empty is left out, as in a Row or Stack and as on Android; before, iOS drew it.
- **Onboarding image alt text is set in the Console**, in the image block's new "Alt text" field, and read
  out as the image's accessibility label. A blank value is now announced as "Image", as an unset one is
  (it was announced as nothing).
- **Paywall images use their Alt Text as the accessibility label.** The Console's "Alt Text" on an image
  section (`alt`) is now read out by VoiceOver; before, it was saved and ignored.
- **In-app messages honour "Allow Dismiss" and "Dismiss Delay".** With dismissal off, a message draws no
  close button or dismiss text and ignores a tap on its backdrop; with a delay of N seconds, the close
  button appears after N seconds and the message can't be dismissed before then. The CTA and the secondary
  button keep working, and a message with neither stays dismissable, so the user always has a way out.
  Applies to banner, modal, fullscreen and tooltip messages. Before, the SDK always showed the close button.

## [1.0.85] — 2026-11-03

Security update: the SDK requires Cloud Firestore 12.19.3 or later. **Rebuild and republish your app** after
updating; an installed build keeps the certificates it was built with.

### Security

- Firebase reported that Cloud Firestore's Apple SDK compiles in TLS root certificates that trusted intermediate certificate authorities whose private keys were compromised (eMudhra, revoked on 17 October 2026). A network attacker holding such a certificate could impersonate the Firestore servers to an app built with an older Firestore. Firestore 12.19.3 removes them; no 11.x release has the fix.
- CocoaPods: `FirebaseFirestore` `>= 12.19.3, < 13.0` (was `>= 11.0, < 13.0`). Swift Package Manager:
  `firebase-ios-sdk` `12.19.3..<13.0.0` (was `from: 11.0.0`, which resolved the unpatched 11.x line). If your app
  pins Firebase below 12.19.3, raise it; resolution fails rather than building against a vulnerable Firestore.

## [1.0.84] — 2026-11-03

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
  pinned buttons together, and stops as soon as the user scrolls the step), and a step that displays a Google answer draws a small "Google Maps"
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
- **A single-select field and a chips field follow the same rule when a host writes a value mid-step.**
  A single-select Select draws no row checked when its stored value is not a String (a host-patched
  `2`); it kept drawing the previous pick. Chips draw a list only when every element is a String, and a
  lone String as one chip; a `[1]` or `["a", 2]` patch kept the previous chips drawn, so the next tap
  toggled them back into the answer.
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
