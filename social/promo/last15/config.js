// The LAST15 campaign: a photo post (1080x1350) and its story frame (1080x1920).
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
  },

  // The note is printed (Archivo); only the sign-off is handwritten. A scan of a real handwritten
  // sign-off can replace it: put a transparent PNG in scans/ and name it here
  // (e.g. post: 'scans/signoff.png'). The typed one then stays hidden.
  signoffScans: { post: '', story: '' },

  post: {
    label: 'FLIM · invite only',
    note: [
      "We're letting [[15]] more people into FLIM.",
      "Get in now and you're first in line for everything we make next.",
      'Code [[LAST15]], two days only.',
    ],
    signoff: 'The team at FLIM',
  },

  story: {
    label: 'FLIM · invite only',
    note: [
      "We're letting [[15]] more people into FLIM.",
      "Get in now and you're first in line for everything we make next.",
      'Code [[LAST15]], two days only.',
    ],
    signoff: 'The team at FLIM',
    link: 'Link in bio',
  },

};
