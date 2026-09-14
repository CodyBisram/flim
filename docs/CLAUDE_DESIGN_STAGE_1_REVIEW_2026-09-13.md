# FLIM v2 — Claude Design Stage 1 review

Reviewed September 13, 2026, in the open Claude Design project **Stage 1 design directions**, page **FLIM v2 - Stage 1 Directions**. Reviewed the actual rendered directions at 100% and 75% canvas zoom and their accompanying accessibility text. Stage 2 had already begun; this review concerns the revised Stage 1 board, not a full verification of the Stage 2 prototype. No design answers, comments, or prompts were submitted, and no application code was changed.

## Verdict

The chosen direction is sound: Warm darkroom as the foundation, clearer social controls from Pocket camera, and date-led organization from Personal photo journal on pages. Stage 1 gives us a useful direction to develop, but its rendered quality and interaction hierarchy are not ready to serve as the final design-system reference.

The strongest improvement is making friends the entry experience while keeping the camera prominent. The biggest remaining challenge is making the screens feel like a place to recognize and respond to people. Large photographs alone do not complete that job.

## What works

- Three actual visual explorations use comparable content. Full-bleed imagery, inset journal layouts, and contained photo cards produce meaningful compositional differences.
- The camera destination is visible, with an understandable distinction between Personal and a named roll. Pocket camera's destination treatment is particularly legible conceptually.
- The product contract preserves per-photo reactions/comments, private sorting, shared-roll anticipation, distinct Activity, and explicit deep-link intent.
- Earlier corrections are incorporated: iOS 18 is acknowledged, Activity follow-back is classified as existing, and followed/nonfollowed page examples are distinguished.
- The journal page makes a person's identity easier to scan than the large-cover variant. Its readable month organization is a useful direction to explore further.
- The design sensibly treats a new launch surface as a proposed client change, separate from production deployment.

## Changes needed before these patterns become the v2 system

### 1. Repair the typography implementation

In the rendered phone screens, handles, captions, profile information, buttons, and much metadata appear in a serif typeface. The board describes native SF Pro typography, so the implementation does not match its stated direction. This could be a font fallback or inheritance problem; the underlying CSS was not inspected, so the exact cause is unconfirmed.

Define the phone's font family explicitly, including form controls and nested components. Essential text should use the intended native-style sans serif. Keep any deliberate editorial type choice limited, named, and justified. Review at 100% before comparing aesthetic directions again.

### 2. Show complete, consistent navigation inside the phones

The written recommendation is four tabs: Feed/Friends, Camera, Darkroom, Rolls. The rendered examples do not reliably show that persistent bar; some content approaches the home indicator while navigation is absent. The accessibility tree contains tab labels that are not visible in the screenshots, suggesting a positioning or clipping issue that needs inspection.

Direction 1c also describes a different five-destination bar in its content: Friends, Darkroom, Camera, Rolls, You. That is neither selected Model A nor the written Model B with Activity.

Pin the intended tab bar above the home-indicator safe area. Give scrolling content its own region. Keep the same selected navigation in the final composite. If Camera intentionally hides the tabs, show its clear exit path and explain the modal presentation rather than implying persistent tab navigation.

### 3. Fix the profile cover/avatar overlap

In 1a, the cover visibly obscures the upper part of the avatar and its initial. The intended overlapping avatar should remain fully legible above the cover edge. Inspect stacking and clipping.

Also reconsider hierarchy: a large cover, counts, full-width Following control, relationship context, and Chapters all precede much of the recent photo collection. For a person you already follow, recent everyday sharing should be easy to reach. Try a compact identity area with a quieter Following state and a clear route into months. Keep the existing selected direction; this does not require discarding personalization.

### 4. Make social controls genuinely explicit

Pocket camera improves reaction discoverability with a visible React button and frame position. But its comment action still reads as a speech bubble and count, despite being presented as a labelled-control direction. Warm darkroom relies on small emoji pills and a small comment control.

Use readable React and Comment labels in the selected composite. Separate existing responses from the action to add one. Demonstrate zero comments, several comments, selected reaction, and pending feedback. Keep a clear `1 of 2` cue; a perforated strip with two tiny thumbnails and a long empty track spends space without making the second frame sufficiently obvious.

### 5. Balance photographs with response visibility

Full-bleed 3:4 photos are attractive, but their height plus the header and film strip pushes captions and conversation low in the initial view. The claim that someone can read a whole day without leaving the fold is not supported by the rendered example. Likewise, “~9% more photo area” and “90pt per frame” are assertions without a demonstrated measurement method.

Optimize the space above the photograph before compromising its composition. Compare the whole viewport with the actual tab bar, a caption, and visible response controls. A little scrolling is acceptable. Do not justify a direction solely through unverified density claims.

### 6. Make the review board readable

The introductory area has a dark background, while the direction section renders on a pale background with very light explanatory text. Labels and rationale are difficult to read. The fourth nonfollower example also extends beyond the visible comparison area.

Use a consistent review-board background with appropriate text colors. Put the additional nonfollower state in its own row or make horizontal navigation explicit. This is a presentation-artifact problem, distinct from the app's dark theme, but it makes judging the design unnecessarily difficult.

### 7. Strengthen the sense of people

The repeated calibration images and initial avatars are adequate for layout exploration, but they cannot demonstrate the emotional appeal of everyday sharing with friends. This is a limitation of the evidence, not a requirement to use private photographs.

Use approved or licensed demo assets showing varied everyday situations and recognizable fictional identities. Prefer readable display names, with handles secondary where useful. A few specific captions and credible short exchanges will help test whether the design invites a response. Keep the small-community scale.

## Product assumptions to tighten

- **Activity frequency:** the board dismisses a fifth tab partly because Activity would be “empty most weeks” for a two-to-five-friend account. That is an unsupported assumption and conflicts with the hoped-for response loop. Keep Model A because it is a reasonable compact structure, then test whether people find responses.
- **Launch continuity:** “Feed at top” and “preserving scroll position within the session” need precise definitions. An ordinary foreground return should not unexpectedly discard reading position. Distinguish cold launch, resume, explicit tab reselection, and notification entry.
- **Friend discovery:** first launch cannot always go straight to a known person's photographs. Campaign invitees may not know the inviter. Show the honest no-known-person path in the next stage.
- **Audience exceptions:** the followed/nonfollowed examples are improved, but the contract should still preserve explicit photo-tag access where applicable. Avoid turning the normal nonfollower shell into a blanket statement that no individual photo can ever be accessible.
- **Cache wording:** describe clearing the relevant page presentation caches precisely. Do not imply unfollow immediately erases every previously downloaded image or revokes every issued URL.
- **Seven-day language:** distinguish the recent window, the new/seen seam, and durable history. “Nothing is removed from the feed” is too broad without qualification. Photos can remain on pages even after leaving a recent view.
- **Share icon:** the paper-plane control beside Following can suggest direct messaging. Label its actual purpose or use a clearer share-profile affordance; DMs are outside the brief.
- **Accessibility:** a stated 46pt button is only one part of accessibility. Native text scaling, contrast, focus order, keyboard behavior, and real hit areas still need the promised system and state boards. Their absence is expected at Stage 1, not proof of failure.

## Suggested next instruction to Claude Design

Continue with the selected Warm darkroom direction, labelled social controls, date-led personal pages, Model A navigation, and Feed-first entry. Before formalizing the system, correct the implementation issues visible in Stage 1: serif-looking fallback text, the obscured profile avatar, missing/clipped tab bars, and pale review-board text on a pale background. Keep the final navigation consistent across screens.

Produce one revised composite showing Friends, Camera, followed page, and nonfollowed page at the same native phone size. Show the tab bar and safe areas in full. Use explicit React and Comment labels and a clear per-photo position indicator. Make the person's identity and recent sharing easier to scan; keep Following and counts secondary once the relationship exists. Clarify the paper-plane action so it does not imply DMs.

Keep photos uncropped in primary viewing, but reduce unnecessary header/filmstrip space so conversation remains reachable. Replace unsupported claims about photo-area gains, Activity frequency, and which option is inherently better for sparse accounts with concrete comparisons and testable hypotheses.

Specify cold-launch versus foreground-resume behavior, preserve explicit navigation intent, and retain the photo-tag audience exception. Then carry the corrected patterns into the Stage 2 component and state boards and prototype. The objective is everyday social ease and a recognizable FLIM identity, not simply proximity to v1.
