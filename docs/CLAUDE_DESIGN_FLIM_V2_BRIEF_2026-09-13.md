# FLIM v2 — Claude Design master brief

Prepared September 13, 2026. Repository reference: `f13f95b`. This is a design commission, not authorization to modify or deploy the application.

## How to use this

Claude Design's open creation screen currently shows **Mobile app design**, **Nocturne** as the selected design system, and **lapse-demo** as the attached codebase. The model selector currently shows **Opus 5**. These are observed settings, not a claim that every account has the same options.

Use the Mobile app design template. Keep the codebase attached as reference. Treat Nocturne as a possible starting reference: its name alone does not establish that it fits FLIM. Ask for a separate **FLIM v2** system so an inherited theme does not dictate the redesign. Do not replace an organization-wide default as part of this exploration.

Paste the entire **Master prompt** section below. Alternatively attach this file and send: “Read the Master prompt in the attached FLIM v2 brief as my design commission. Begin with Stage 1, including the visual explorations on the canvas.” The staged process intentionally produces something concrete before asking you to choose a direction.

Useful additional context, if not available through the attached repository:

- `docs/EVERYDAY_SOCIAL_AUDIT_AND_PLAN_2026-09-13.md` — product direction and reasoning. Its Batch 0 findings have subsequent fixes; do not treat the old findings as a current defect list.
- `docs/PENDING.md` — current decisions and implementation status; newer entries supersede historical ones.
- Current screenshots of Feed, Camera, Darkroom, Activity, a page, and a shared roll; the FLIM wordmark and approved sample photographs.

The prompt works without screenshots. With source access, Claude should inspect current UI components and assets. Product reference material should not include credentials or private production photos.

### Claude Design features this brief uses

Anthropic documents reference imports, interactive canvas work, direct edits, inline comments, design variations, and handoff to Claude Code. Those suit a staged redesign with reusable components and a testable core flow. Treat any generated web prototype as a design artifact; native SwiftUI implementation still needs engineering. [Claude Design getting-started guide](https://support.claude.com/en/articles/14604416-get-started-with-claude-design).

Claude Design can derive a reusable system from code and visual references, including colors, typography, components, and layouts. Review that system before using it throughout the app. Editing or publishing a shared system is a separate action from exploring a project. [Design-system setup guide](https://support.claude.com/en/articles/14604397-set-up-your-design-system-in-claude-design).

Documented exports include HTML, PDF, and PPTX, with a Claude Code handoff option. For this task, prioritize the interactive project, an HTML export where available, and an engineering handoff. Do not assume editable Figma export or production-ready SwiftUI output. [Claude Design product page](https://claude.com/product/design).

---

## Master prompt — paste from here

You are the lead product designer, native iOS interaction designer, and design-system designer for **FLIM v2**.

Create a complete redesign of our existing iPhone application. I want a coherent product, a distinctive visual identity, a reusable design system, and an interactive prototype of its most important journeys. The deliverable must include actual designed screens on the canvas, not only a strategy document or a collection of attractive isolated mockups.

Work in stages. First show me three focused visual directions and your recommendation. After I select a direction, build the full system and experience described below. Carry this brief forward through the project; do not forget the quieter screens or failure states after designing the home screen.

### 1. The center of the product

**FLIM is a place to share everyday photos with friends, with a camera that makes those moments feel special.**

Possible expression: **Everyday moments. Shared with friends.**

This is the lens for every design decision. An ordinary Tuesday should be enough reason to use FLIM. A coffee, your friend's dog, a walk home, the dinner you made, something funny on the train, a little detail someone else would miss: these belong here.

The core loop is:

**See friends' photos → respond → share a moment of your own → receive a response → return to that person.**

The camera gives those moments a recognizable look and makes taking them enjoyable. Shared rolls bring several people's perspectives together for an occasion. Chapters give everyday sharing a lasting home in monthly memories.

People should be able to open FLIM just to see or respond to a friend. They should not need to take a photo, attend an event, fill a roll, or build an audience before the app feels useful.

FLIM began partly because people missed the social experience they had with Lapse. Learn from that desire for casual, intimate photo sharing, anticipation, and familiar faces. Give FLIM its own identity and interaction language.

The desired feeling is: **“I get to see the small things in my friends' lives, and they get to see mine.”**

### 2. Who we are designing for

We recently shipped 1.5.2 and opened access more broadly through an invite code. We have a small real community, roughly 60–70 accounts in the latest supplied context, and subsequent work on the 1.5.3 train. Source changes and App Store availability are separate; inspect current code without assuming everything in it is shipped.

Design for these people:

- A former Lapse user who wants casual sharing with people they know.
- A friend invited by another friend, who has no idea what FLIM, Darkroom, rolls, or chapters mean yet.
- Someone who enjoys looking and reacting more often than taking pictures.
- Someone who takes several photos in a day but wants to share only one or two.
- A small group using a shared roll for dinner, a weekend, or a trip.
- Someone returning after a quiet week, who should feel welcome rather than behind.

Design an experience that works with **two to five active friends**. Show realistic sparse content, modest reactions, and quiet days. Do not manufacture an impression of a huge social network.

Recorded usage is encouraging for personal sharing and lightweight responses. It is not proof of durable organic retention. We need designs that can be tested with people, not assertions that a visual change will increase retention.

### 3. Read the product before redesigning it

Use the attached `lapse-demo` codebase as a reference. Inspect navigation, the main SwiftUI views, reusable components, copy, assets, and current behavior. Focus on `Flim/Views`, relevant models and services, and recent decisions in `docs/PENDING.md`.

The September 13 everyday-social audit explains the direction. Newer code and PENDING entries supersede its defect list: a subsequent Batch 0 addressed follow/content ordering, notification audience checks, unread acknowledgement, capture warnings, navigation ownership, and other transitions. Preserve the corrected behavior.

Separate your observations into:

1. Existing behavior to preserve.
2. Presentation and interaction changes you recommend for v2.
3. New product behavior that needs an explicit decision or backend work.

Do not silently turn a design proposal into a claim about the current app. When reference material conflicts, flag the specific conflict and use the latest explicit product decision. Keep application source read-only. Build only the design project and prototype artifacts.

### 4. Creative freedom and boundaries

You have substantial freedom to redesign information hierarchy, layout, visual rhythm, typography, component styling, onboarding, empty states, transitions, and the way the core journeys fit together.

You may propose a clearer navigation model, including the role and prominence of Feed, Camera, Darkroom, Rolls, and the personal page. Explain the tradeoffs rather than keeping four tabs simply because they exist today.

Preserve these decisions:

- The product is named FLIM. Keep the supplied identity recognizable; do not rename it.
- Activity remains a distinct destination. The owner previously declined merging it into Feed. It may have a clearer entry point, but retain its separate purpose.
- The camera has one intentionally tuned film look. There is no filter marketplace or editing studio to invent.
- Shared-roll anticipation remains meaningful. Personal photos do not acquire an artificial waiting period.
- Existing friends can enjoy the product without an event or shared roll.
- No algorithmic public discovery feed, influencer dashboards, compulsory posting, forced invitations, mandatory contact access, guilt-based streaks, or engagement leaderboards.
- Direct messages are outside the core v2 scope. Existing comments and reactions should become more usable first.
- Renaming existing rolls was intentionally removed. Do not reintroduce it as routine functionality.
- Core image quality, seeing friends, posting, reacting, and replying should not be paywalled in this concept.

Give us a full redesign within those product boundaries. If you believe a boundary should change, show it separately as an optional decision, with consequences.

### 5. Audience and privacy — make the language honest

“Friends” describes the human purpose. The current permission model is **following**, not mutually approved friendships.

- Following is immediate and one-way; there is no follow-request approval flow.
- Posts are readable by their author and followers, with an explicit photo-tag exception, subject to blocking and other restrictions.
- Someone who follows you can generally see eligible older posts too. Do not imply each post is limited to the followers you had when you posted it.
- A profile's public-facing shell can show identity information; a nonfollower does not get the follower-only photo collection.
- An explicit photo tag is different from an @mention in a comment. Do not make a comment mention silently grant access.
- A photo kept private in Darkroom remains private. Posting it is a separate, intentional action.
- Shared-roll photos follow membership and reveal rules; they are not automatically personal-feed posts.

Design clear, concise audience language at the decision to share. “Your followers can see this” is a starting point, with tagged-person context where applicable. Avoid implying “only approved friends” or a closed private account.

Include readable states for follow pending, follow confirmed, follow failed, unfollowed, blocked, removed content, and unavailable notification destinations. A pending follow should not momentarily present a populated page as empty. An unfollow should not leave an inappropriate photo grid on screen.

Do not promise screenshot prevention, instant deletion from other people's devices, or permission enforcement that exists only in the prototype.

### 6. Visual direction

The current visual foundation is dark, photographic, and restrained: near-black surfaces, warm amber accents, film details, quiet metadata, and large photographs. Personal accents include amber, rose, violet, teal, lime, and sky.

We want the app to feel **warm, immediate, personal, tactile, and easy to read**. Film character should come primarily from photographs and a few deliberate details. The UI should help people notice one another.

Explore three meaningfully different directions using the same content and the same three anchor screens: everyday Feed, Camera, and a person's page. Nine anchor screens total is enough to compare the directions. Do not build the entire app three times.

Possible starting territories, which you may improve:

1. **Warm darkroom:** confident photographic dark surfaces, warm accent, generous image area, readable human typography, minimal film cues.
2. **Personal photo journal:** an intimate sense of dates and accumulated days, thoughtful editorial rhythm, recognizable personal pages, restrained structure around photographs.
3. **Pocket camera, living feed:** a more tactile camera identity paired with fast, exceptionally clear social controls and familiar native navigation.

These must differ in composition, density, type hierarchy, and interaction emphasis, not simply accent color. Keep the app dark for the main v2 proposal. A light-mode concept, if compelling, belongs in an optional future exploration rather than silently doubling the core scope.

Avoid tiny gray body text, ultra-light essential labels, decorative grain over controls, fake camera hardware everywhere, generic dashboard cards, excessive gradients, and oversized branding that pushes friends' photographs below the fold.

Use current photo proportions and framing as constraints. Reference photos are primarily 3:4 portrait. Preserve full photographs in primary viewing; explicitly document any thumbnail cropping. Never stretch images. Keep an existing burned-in date stamp intact instead of adding a second one.

### 7. Build a real FLIM v2 design system

Inspect any attached system, including Nocturne if it is selected. Determine what actually fits. Establish a separate FLIM v2 system with reusable foundations and components. If Claude Design supports saving this directly as a design system in the current workspace, prepare it for review. Otherwise provide the equivalent organized component board and token specification. Do not claim a system was saved if it was not.

Specify:

- Semantic colors: backgrounds, elevated surfaces, primary and secondary text, dividers, accent, focus, selection, success, warning, destructive, disabled, and loading. Include accessible behavior for all six personal accents.
- Typography: named text roles, sizes, weights, line heights, wrapping, and Dynamic Type adaptation. Use native-system typography where practical. Reserve monospaced or segment-style details for appropriate metadata.
- Spacing and layout: a consistent scale, readable content margins, safe-area treatment, image geometry, keyboard avoidance, sheet spacing, and minimum touch targets.
- Shape and depth: restrained radii, borders, scrims, and elevation with clear reasons for each.
- Iconography: consistent symbols and stroke weights, active and inactive states, and accessible names. Essential actions must be understandable without decoding a custom symbol.
- Motion and haptics: a small vocabulary for capture, selection, reaction, navigation, sorting, and reveal. Give timing and Reduce Motion alternatives. Long animations must be skippable where appropriate.
- Component anatomy, variants, states, usage rules, and content constraints.

Include navigation, headers, buttons, icon buttons, destination selectors, avatars, relationship controls, photo cards, multi-photo position indicators, reaction controls, comment rows/composer, activity rows, audience labels, upload status, empty/error states, search results, roll cards, chapter covers, sheets, toasts, and confirmations.

Demonstrate those components with real content and long-content variants. A token sheet without reusable screen components is incomplete.

### 8. Information architecture and launch behavior

Answer visibly:

- Where do I see my friends?
- How do I take a photo quickly?
- Where are my private photos?
- How do I know someone responded?
- Where do my shared photos live over time?
- Where does a group roll belong?

Current navigation is Camera, Darkroom, Rolls, and Feed, with Activity and profile entered from Feed. Camera is the current default launch surface.

Compare the current entry behavior with a social-first return and a last-used-surface return. Recommend one for the prototype, distinguishing first-ever launch, ordinary return, and explicit deep-link entry. Prototype navigation is a proposal, not an instruction to change production launch behavior immediately.

Always honor explicit intent: a notification should reach its photo or conversation; a roll invitation should reach its roll context; a user choosing “View” after posting should reach that destination. First-sort completion currently defaults to Darkroom when there is no explicit destination.

Keep Camera quickly reachable. Keep Activity distinct. Avoid a maze of overlapping sheets or a tab bar crowded with every feature. Show back, dismiss, and return behavior, including preserved Feed position and the selected frame.

### 9. Complete screen and journey coverage

#### A. Invitation, account creation, and first value

Design ordinary invitation and shared-roll invitation entry, code entry/recovery, email verification, username/profile setup, and the transition into the app. Authentication is email OTP, not SMS. A valid roll code can also provide app admission. Preserve invitation context across the steps where possible, and show a manual code or reopened-link fallback when deferred linking is unavailable.

Explain the app with one clear promise and minimal teaching. Let people connect with a known person and see value without a forced follow quota. Distinguish a genuine personal inviter from the owner of a widely distributed campaign code.

Request camera access in context, with a useful denied-permission path. Treat notification permission as a contextual benefit, not a gate to participation. Avoid repeatedly prompting after refusal.

Cover first launch with a known friend, no known people yet, no posted photos yet, invalid/expired code, verification failure, keyboard visible, and returning authentication.

#### B. Everyday Feed

Make friends' photos the visual center. Show a credible day with a handful of familiar people, ordinary photographs, short captions, and modest interaction.

The existing Feed is chronological and groups photos by person/day. Multiple frames have their own reactions, comments, and captions. Preserve those semantics even if you improve presentation. It must be obvious that another frame exists and which frame a reaction or comment belongs to.

Show one-photo and multi-photo entries, readable reaction and comment affordances, a new-frame cue, the transition into comments, and return to the same frame and scroll position.

The recent Feed uses a seven-day window; older posts remain in pages and chapters. A caught-up state should explain what it means and offer a useful next step without implying older memories were deleted. Distinguish no friends followed, friends with no recent posts, caught up, loading, offline cached content, and failed refresh. Preserve visible content during refresh.

#### C. Camera

Make capture immediate, enjoyable, and reachable with one hand. Respect the live viewfinder and shutter hierarchy. Preserve the single film look; do not introduce filter selection or a complicated editor.

Make destination unmistakable before capture: personal/private versus a named shared roll. Explain the difference without covering the viewfinder with instructions.

Represent locally saving, safely saved on the phone, uploading, offline queued, and uploaded states honestly. An image that is only in memory must not be described as safely saved. Keep relevant warnings visible until durability is established. A retry should belong to the affected shot.

Personal photos become available after processing/upload without a theatrical development delay. Shared-roll photos stay hidden until their reveal. Do not conflate network transfer with developing.

Show camera permission denied, capture in progress, temporary offline use, and background/resume behavior in the handoff. Hardware can be simulated in the prototype; identify that simulation outside the product UI.

#### D. Darkroom and sharing

Make the distinction between personal keeping and social sharing easy for a new person to explain.

The existing sorting decisions are **Keep private**, **Post to page**, and **Delete**, with undo. Keep is not the same as saving to the phone's Photos library. Captions and tags are optional; simple sharing should stay simple.

Design unsorted photos, the sort interaction, private collection, optional caption/tag entry, an audience explanation, successful posting, failed posting, undo, and an empty Darkroom. If you propose new naming, show why it is clearer and how existing users will recognize it.

After a successful post, acknowledge what happened and provide a meaningful next action without adding a modal every time. Explicit “View” intent must win over automatic destination changes. Do not invent a durable offline post queue as current functionality; label any such proposal as new work.

#### E. Reactions, comments, and Activity

Make responding feel easy and personal. Existing emoji reactions, comments, comment likes, photo tags, and mentions should become clearer rather than being presented as new features.

Show adding/removing a reaction, a pending write and recoverable failure, comment composition with keyboard, a short thread, long text, and a notification opening its exact photo/thread. Preserve the difference between photo tags and comment mentions.

Activity should answer: **Who responded, to what, and what can I do next?** Include the relevant thumbnail, person, action, time, and readable unread treatment. Cover reactions, comments, mentions, follows, and follow-back where appropriate. Do not inflate unread counts or mark unseen incoming events read merely because an earlier load finished.

Show an empty inbox, a quiet inbox, a busy inbox, missing/deleted content, and changed access. Keep notification previews consistent with the audience. A gentle unavailable state should let someone continue without disclosing protected content.

#### F. People and discovery

Make finding someone by name or username work well. Show search loading, useful results, no match, retryable failure, and an offline state separately.

Use real relationship context when available: someone who follows you, a rollmate, a personal inviter, mutual connections. Do not label arbitrary members as friends or pad a sparse list with strangers. Contacts permission is not a prerequisite.

Design the path from a known person's result to following, seeing eligible photos, responding, and returning. Keep invite sharing available without making it a growth chore.

#### G. My page, other pages, and Chapters

Make a page feel like a person's accumulated life, with a clear identity and photographs. Balance avatar, bio, cover/personalization, accent, counts, photo grid, and monthly chapters so identity does not crowd out images.

Distinguish my page from another person's page and a nonfollower view. Make editing and private settings findable without exposing them as public-page clutter.

Chapters organize posted photos into monthly memories. Show a first week with only a few photos, an established month, older months, chapter playback, and a restrained closing/recap moment. There should be value before a complete month exists.

Do not turn chapters into a performance report. Avoid ranking friendships or making inactivity feel like failure. Cover selection or curation changes can be proposed, but mark them as new behavior if absent from the current app.

Respect export rules: users can export their own photos; members can save shared-roll photos from the appropriate roll experience. Other people's Feed/chapter photos do not automatically have that export affordance. Do not use ownership-ambiguous UI to imply permission.

#### H. Shared rolls

Keep rolls easy to understand as a shared camera for an occasion. Design list, creation, invitation, join preview, successful join, active roll, waiting, ready-to-reveal, reveal, and developed collection.

Show who is participating, how to contribute, the selected capture destination, and the reveal time. Nobody, including the photographer, sees hidden roll photographs before reveal. Contribution summaries must not leak previews.

The current default reveal delay is approximately twelve hours, with bounded creator adjustments. Use current source rules for controls and the member cap; the existing cap is fifty. Show full, invalid, expired, unavailable, and already-joined conditions where applicable.

Make the reveal special through photographs and pacing, with usable playback controls and Reduce Motion behavior. The closing moment should offer responding, viewing the collection, or continuing together. Existing “start another with this group” invites prior members; it does not automatically add them. Show Join/Not this time and a reliable transition after closing the reveal.

Include member mute, invite sharing, and eligible save/export, including partial export failure. This feature should remain valuable without becoming a prerequisite for everyday sharing.

#### I. Settings, support, and trust

Include profile editing, personal accent, notification status/preferences actually supported, roll mute entry points, blocked people, report content/person, feedback/support, sign out, account deletion with consequences, and required-update handling.

Use concise, specific confirmations for consequential actions. Do not add alarming confirmation dialogs to every reversible tap. Settings should be calm, searchable by ordinary human understanding, and consistent with the main app's design system.

### 10. Prototype behavior and state coverage

Build an interactive prototype with a small consistent fictional group: Alex, Maya, Jonah, Rae, and Sam. Reuse people, photos, captions, relationships, and notifications across screens so journeys connect coherently. Include everyday subjects rather than only travel campaigns and polished portraits. Use supplied approved images or appropriately licensed demo assets; track their source. Avoid real production-user content.

At minimum wire these journeys end to end:

1. Personal invite → email verification simulation → find the known friend → follow → see their photos → react to their second frame.
2. Ordinary return → browse friends → capture a personal photo → keep one private → post another with an optional caption → view the successful result.
3. Notification → exact photo/comment → reply → return to the previous context without losing position.
4. Roll invitation → understand the reveal → join → capture into that roll → wait → reveal → respond → invite the group to another roll.
5. My page → older month → chapter → eligible own-photo export, with a clear distinction from restricted export on another person's page.

Add a reviewer-only scenario switcher or separate state board for cold start, populated account, offline, slow network, denied permissions, long text, and largest text size. This is prototype tooling, not an app feature.

Primary buttons must lead somewhere meaningful. Secondary functions that are not wired must be identified in a coverage checklist. Do not imply that account creation, push delivery, camera capture, payments, or backend authorization are actually live.

### 11. Accessibility and native quality

Target a native iPhone app implementable in SwiftUI, including iOS 18 support unless current project settings establish a newer minimum. The prototype may use web technology, but its interaction model must make sense on iOS.

Show a compact iPhone layout and a larger one; document adaptation between them. Honor safe areas, status/navigation bars, home indicator, keyboard, and one-handed reach. Avoid desktop sidebars or hover-only controls inside a phone frame.

Minimum design requirements:

- At least 44 × 44 point touch targets, including small visible icons with larger hit areas.
- Readable text with adequate contrast; validate ordinary text at 4.5:1, large text and meaningful UI boundaries at 3:1 where applicable.
- Dynamic Type through the largest accessibility sizes, using reflow and alternate layouts rather than clipped labels.
- VoiceOver labels, logical reading/focus order, selected state announcements, and accessible descriptions for key photo actions.
- No essential meaning conveyed only by accent color, gesture, animation, or haptic feedback.
- Reduce Motion alternatives and no unnecessary flashing effects.
- Legible disabled, empty, warning, and destructive states, including in daylight.
- Multiline names, long captions, emoji, localization expansion, and keyboard-visible comment/authentication screens.

Distinguish checks actually performed in the prototype from native-device checks that engineering must perform later.

### 12. Performance, image quality, and operating cost

We are a small independent app. We have paid roughly $25/month for Supabase and are considering R2 for storage and egress. Growth increases storage, requests, and delivery costs. A redesign should support an efficient product without making the photos worse.

Favor image-first layouts that work with thumbnails for collections, an appropriate feed rendition, and a larger asset only when needed. Reserve image dimensions to avoid layout jumps. Keep existing content useful during a refresh. Design a subtle asset-level retry rather than replacing a whole screen with an error.

Avoid autoplaying heavy media, downloading entire archives on entry, endless decorative animation, and a new cloud-processing requirement for every ordinary interaction. Do not change compression, film rendering, or archival retention as a visual-design decision.

Place potential monetization in a separate short appendix: perhaps optional supporter identity, useful memory/export enhancements, or paid occasion-hosting features. Explain who pays and what recurring cost the feature creates. Do not set a price or promise unlimited storage without a financial model. Do not introduce ads into the core prototype or charge people merely to receive their friends' responses.

### 13. Success and usability evaluation

Judge the design by whether people understand and complete the social loop, not by how cinematic its opening screen looks.

Prepare a short moderated study for five people, including former Lapse users and people new to the category. Tasks should cover finding a known friend, recognizing multiple photos, responding, understanding keep-private versus post audience, returning to a reply, and joining a roll. Test with both sparse and established accounts.

Record completion, hesitation, misinterpretation, and participant language. Include the questions “Who can see that photo?” and “What would bring you back tomorrow?” Do not tell participants the intended answer before they try.

Useful product measures include first meaningful social action, receiving a response after sharing, returning after a response, and weekly reciprocal participation between distinct people. Keep personal-post and roll behavior distinguishable. No visible social score. Small pilot results are directional evidence, not a statistically conclusive growth claim.

### 14. Work stages and deliverables

**Stage 1 — direction and structure**

Read the references, identify the current product contract, and state your interpretation in a short paragraph. Produce the three visual directions on the canvas using the same Feed, Camera, and page content. Include a proposed navigation map and launch-behavior comparison. Recommend one direction with practical reasons and identify any important assumptions. Then ask me to choose or adjust the direction before expanding every screen.

**Stage 2 — system and core loop**

After selection, establish FLIM v2 tokens and components. Build the connected everyday loop first: Feed → photo response → Camera → private/share decision → posted result → Activity → reply. Show the sparse-account version alongside the populated version. Refine the loop before expanding the feature inventory.

**Stage 3 — complete application**

Apply the system across onboarding, people discovery, personal/other pages, Chapters, shared rolls, settings, trust, and their significant states. Keep a screen/state coverage matrix so omissions are explicit. Full coverage does not mean inventing a unique layout for every minor error; demonstrate reusable patterns and show their application.

**Stage 4 — critique and handoff**

Review the work for visual consistency, ordinary-language comprehension, audience accuracy, accessibility, reachability, and implementation feasibility. Fix identified problems. Deliver:

1. A concise product concept and explanation of navigation decisions.
2. The selected design direction and reusable FLIM v2 system.
3. An organized board of finished screens and meaningful variants.
4. A clickable prototype of the five required journeys.
5. A screen/state coverage matrix with implemented, illustrated-only, and outstanding items.
6. A copy inventory for onboarding, audience explanations, empty states, errors, and important confirmations.
7. Engineering handoff: component names, token values, layout rules, routes, state transitions, motion, accessibility, and asset provenance.
8. A change map separating presentation-only work, client behavior changes, backend-dependent proposals, and unresolved product decisions.
9. A practical v2 rollout plan: coherent increments, migration guidance for existing users, device checks, and usability validation. Separate visual/navigation experiments so their effects can be understood.
10. The optional monetization appendix, clearly outside the essential v2 experience.

Use Claude Design's canvas, reusable systems, comments, and available export/handoff tools where supported. Provide an interactive HTML export if available and a concise review document. Keep exploration variants clearly separate from the selected handoff. Do not claim unsupported Figma or native-code export. Do not publish the project or modify the production repository.

### 15. Final quality bar

Before calling the design complete, verify:

- A new person can explain FLIM as everyday photo sharing with friends.
- Seeing and responding to people feels as central as taking photographs.
- Camera access remains fast and delightful.
- Private photos, posted photos, and hidden roll photos are distinguishable without a tutorial.
- A second frame and its own comments/reactions are discoverable.
- An explicit user action reaches the promised destination.
- Two active friends are enough for the populated experience to feel credible.
- A quiet week does not feel like a failure.
- The app is readable and usable at large text sizes.
- Photographs retain their character and composition.
- Shared rolls and Chapters reinforce the product rather than competing to be its main purpose.
- The screens form one consistent product, including settings and error states.
- New features and simulated behavior are labeled honestly in the handoff.

Be decisive and specific. Spend your effort on the screens, interactions, and details that make people want to share small parts of their lives with one another. Start Stage 1 now.

## End of master prompt

---

## Useful follow-up prompts

### After choosing a direction

“Proceed with direction [name]. Preserve its strongest visual choices, establish the FLIM v2 component system, and build Stage 2's complete everyday loop. Show both a two-friend account and an established account. Keep the audience rules and explicit navigation intent from the original brief.”

### If the output becomes attractive but generic

“Review these screens against FLIM's purpose. Make the people, ordinary photographs, and reciprocal interactions more central. Replace generic dashboard patterns with photo-led native layouts. Show the revised Feed, photo conversation, and private-to-post journey using the same content so I can compare the improvement.”

### Before engineering handoff

“Perform Stage 4 now. Exercise every required prototype journey, identify disconnected controls and missing states, and correct them. Package only the selected direction as the implementation reference. Separate source-backed behavior from proposed behavior, and identify every proposal requiring backend work. Provide the component, route, state, accessibility, and copy specifications without modifying application code.”
