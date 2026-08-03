const { digestCopy } = require("./digest.js");
let pass = 0, fail = 0;
function eq(label, got, want) {
  if (got === want) { pass++; }
  else { fail++; console.log(`FAIL ${label}\n  got:  ${got}\n  want: ${want}`); }
}
let c;
c = digestCopy(["ana"], 1);
eq("one person one photo / title", c.title, "@ana posted");
eq("one person one photo / body", c.body, "Tap to see it");

c = digestCopy(["ana"], 4);
eq("one person many / title", c.title, "@ana posted");
eq("one person many / body", c.body, "4 new photos to catch up on");

c = digestCopy(["ana", "ben"], 2);
eq("two people / title", c.title, "@ana and @ben posted");
eq("two people / body", c.body, "2 new photos to catch up on");

c = digestCopy(["ana", "ben", "cal"], 5);
eq("three people / title", c.title, "@ana, @ben and @cal posted");

c = digestCopy(["ana", "ben", "cal", "dee"], 9);
eq("four people / title", c.title, "@ana, @ben and 2 others posted");
eq("four people / body", c.body, "9 new photos to catch up on");

c = digestCopy(["ana", "ben", "cal", "dee", "eve", "fay"], 12);
eq("six people / title", c.title, "@ana, @ben and 4 others posted");

// A title should never run away with the number of posters.
const long = digestCopy(Array.from({length: 40}, (_, i) => `user${i}`), 99);
eq("forty people stays short", long.title.length < 45, true);
eq("forty people / body", long.body, "99 new photos to catch up on");

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
