// The LAST15 campaign: a photo post (1080x1350), its story frame (1080x1920) and a 15 second reel.
// Everything editable is here. Open campaign.html in Chrome to see it; render with
//
//   node social/promo/last15/render.mjs
//
// Copy rules (from the brief): no em dashes, plain words, no exclamation marks, no personal
// names, the sign-off is always "The team at FLIM", and the only numbers are 15 and 100.
// In the copy, wrap the amber words in [[ ]]: only "15" and "LAST15" are ever amber.
window.CAMPAIGN = {
  colors: { bg: '#0c0908', text: '#f4efe7', dim: '#a79c8e', amber: '#e8a44c', mount: '#ece4d6' },

  // The film look on every photograph, 0 to 1 (warm, a little faded), and the grain.
  grade: 0.8,
  grain: 0.4,

  // Photos are always 3:4, never cropped square. Paths are relative to this folder. Leave a
  // slot as '' to see a placeholder frame.
  photos: {
    hero: 'photos/church-straightened.jpg',
    second: '../spotlight-reel/photos/italy-wisteria.jpg',
    third: '../spotlight-reel/photos/dubai-burj-al-arab.jpg',
  },

  // A scan of real handwriting can replace any handwritten block: put a transparent PNG of it in
  // scans/ and name it here (e.g. post: 'scans/post-note.png'). The type then stays hidden.
  handwritingScans: { post: '', story: '' },

  post: {
    label: 'FLIM · invite only',
    note: [
      "We're letting [[15]] more people into FLIM.",
      'The first 100 keep a Founding badge forever.',
      'Code [[LAST15]], two days only.',
    ],
    signoff: 'The team at FLIM',
  },

  story: {
    label: 'FLIM · invite only',
    note: [
      "We're letting [[15]] more people into FLIM.",
      'The first 100 keep a Founding badge forever.',
      'Code [[LAST15]], two days only.',
    ],
    signoff: 'The team at FLIM',
    link: 'Link in bio',
  },

  // The reel, 15 seconds. Each beat writes its lines on in hand, in order.
  reel: {
    duration: 15,
    beats: [
      { at: 0.2, photo: 'hero', lines: ['A note from the small team', 'that makes FLIM.'] },
      { at: 3.0, lines: ["We're letting [[15]] more", 'people in.'] },
      { at: 5.8, photo: 'second', lines: ['The first 100 keep a Founding', 'badge on their profile. For good.'] },
      { at: 9.0, photo: 'third', code: true, lines: ['Friday and Saturday only.', 'Then the code is gone.'] },
      { at: 12.0, close: true, lines: ['Code [[LAST15]].', 'Link in bio.'] },
    ],
    signoff: 'The team at FLIM',
  },
};
