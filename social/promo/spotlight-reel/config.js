// Everything a person might want to change in the Spotlight reel lives here.
// Edit this file (or use the Edit panel when reel.html is open in a browser, then "Download
// config.js" and drop it over this one), then re-render:
//
//   node social/promo/spotlight-reel/render.mjs
//
// Photos are paths relative to this folder. Any 3:4 portrait JPEG works; drop Italy or Oregon
// frames into photos/ and point a slot at them.
window.REEL_CONFIG = {
  // The app's own accent: amber, rose, violet, teal, lime or sky (FlimAccentPalette), or any hex.
  accent: 'amber',

  // Film look over every photograph: 0 is the photo as developed, 1 is a strong warm disposable.
  grade: 0.8,
  // Film grain over the whole reel, 0 to 1.
  grain: 0.55,

  // The person whose frame gets chosen: the viewer of the phone.
  // avatar: a photo path for your profile picture, or '' for the initial.
  me: { name: 'Cody', handle: 'cody', number: 1, bio: 'Knicks in 5', avatar: 'photos/avatar-cody.jpg',
        shared: 42, followers: 118, following: 96 },

  // Your post, the one you put up and that gets chosen.
  // Its photo also opens the reel full screen, so it should be the sharpest one you have.
  myPost: {
    photo: 'photos/italy-beach-jersey.jpg',
    // The shots from the same day, shown in the card's film strip (hidden for a one-shot day,
    // as in the app).
    strip: ['photos/italy-beach-jersey.jpg'],
    meta: '1 shot · 1:20 PM',
    caption: 'the og anunoby jersey on the amalfi coast',
    reactions: [['❤️', 6], ['🔥', 3], ['😂', 0]],
    comments: 4,
  },

  // A friend's day under the strip.
  friendPost: { handle: 'aly', meta: '3 shots · 10:12 AM to 6:40 PM', newCount: 1,
    photo: 'photos/italy-wisteria.jpg',
    strip: ['photos/italy-florence-duomo.jpg', 'photos/italy-st-peters.jpg', 'photos/italy-wisteria.jpg'] },

  // The contact sheet the team chooses from: nine frames people put up this week.
  sheet: [
    'photos/dubai-lamborghini.jpg', 'photos/bali-bamboo-pool.jpg', 'photos/italy-wisteria.jpg',
    'photos/dubai-burj-dinner.jpg', 'photos/italy-beach-jersey.jpg', 'photos/italy-florence-duomo.jpg',
    'photos/dubai-burj-al-arab.jpg', 'photos/italy-st-peters.jpg', 'photos/bali-cocktail-sunset.jpg',
  ],
  // Which of the nine get chosen (0-based, in the order they sit in the Spotlight strip), and
  // whose they are. "me" is you: put your own post's photo at that position in the sheet.
  chosen: [1, 4, 6, 7, 5],
  chosenHandles: ['ash', 'me', 'arman', 'ricky', 'aly'],
  // Whose frame is whose: arman's is Dubai, ricky's and aly's are Italy (they shot those).
  // Spare handles for other slots: tristan, lele, stephen, alyssa.

  // Your page.
  cover: 'photos/dubai-marina-yacht.jpg',
  pageGrid: ['photos/italy-beach-jersey.jpg', 'photos/dubai-lamborghini.jpg', 'photos/bali-ocean-sunset.jpg',
             'photos/dubai-sheikh-zayed-road.jpg', 'photos/bali-temple-deck.jpg', 'photos/dubai-marina-yacht.jpg'],

  // The week the strip names: the latest published week on the day this posts. Always a Monday.
  week: '2026-09-21',
  clock: '9:41',

  // The words around the phone. Plain sentences, no em dashes, per docs/COPY.md.
  copy: {
    hookEyebrow: 'New in FLIM 1.6',
    hook1: 'Your best frame this week',
    hook2: 'could be in Spotlight.',
    step1Eyebrow: 'Once a week',
    step1: 'Put one frame up.',
    step1Sub: 'Only the team at FLIM sees it.',
    step2Eyebrow: 'The week of',   // followed by the week, e.g. "The week of September 14"
    step2: 'The team at FLIM chooses a few.',
    step3Eyebrow: 'Spotlight',
    step3: 'Chosen frames reach everyone on FLIM.',
    step4Eyebrow: 'Yours to keep',
    step4: 'A badge and a shelf on your page.',
    endLine: 'Spotlight is here.',
    endSub: 'Shoot film with your friends.',
    cta: 'Update to 1.6',
    ctaCode: 'Link in bio. Get in with',
    code: 'SPOT26',
    // Under the code, smaller.
    founding: 'Invite only. 20 spots left in the Founding 100.',
    codeWindow: 'The code works for a week, even after they fill.',
  },

  // The soundtrack (Spotlight_Reel_1.wav, 26.8 s, a beat every 0.68 s). The reel runs as long as
  // it does. The scenes are designed on a 20 s clock; each pair here pins a moment of that design
  // clock [right] to a beat of the track in seconds [left], and everything between is stretched
  // evenly. Stretching a quiet stretch gives it more reading time.
  audio: 'spotlight-reel.wav',
  duration: 26.8,
  timeline: [
    [0, 0],
    [2.86, 2.42],   // the match cut into the phone
    [4.54, 3.9],    // the finger on the post's menu
    [6.24, 5.5],    // the first-time sheet is up...
    [8.3, 6.42],    // ...and read, then "Put it up" is tapped
    [11.02, 8.78],  // the contact sheet
    [13.74, 11.22], // the chosen fly into the phone
    [16.46, 13.95], // the push drops in...
    [18.5, 15.25],  // ...and is read, then your page opens
    [19.86, 16.55], // the badge tap
    [21.9, 18.02],  // the end card, held through the fade
    [26.8, 20],
  ],

  // The burned-in date on the end card, like a disposable's date back.
  stampDate: "09 29 '26",
};
