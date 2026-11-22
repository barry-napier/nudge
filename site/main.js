const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
const systemDark = matchMedia('(prefers-color-scheme: dark)');
const isDark = () => (document.documentElement.dataset.theme || (systemDark.matches ? 'dark' : 'light')) === 'dark';

// Real results from Nudge's Rewriter and Apple's model. Do not polish them.
const demos = [
  {
    menu: 'menu-fix',
    before: 'hey sam can you send me the q3 report by friday, i need it for the board meeting on monday',
    after: 'Hey Sam, can you send me the Q3 report by Friday? I need it for the board meeting on Monday.',
  },
  {
    menu: 'menu',
    before: 'i think we should maybe push the launch to thursday, the onboarding still has a few bugs and i dont want to rush it',
    after: "I think we should maybe push the launch to Thursday. The onboarding still has a few bugs, and I don't want to rush it.",
  },
  {
    menu: 'menu-direct',
    before: 'i think we should maybe push the launch to thursday, the onboarding still has a few bugs and i dont want to rush it',
    after: "We should push the launch to Thursday. The onboarding still has a few bugs and I don't want to rush it.",
  },
];

// The big demo
const stage = $('#stage');
const draft = $('#draft');
const menu = $('#menu');
const keys = $$('#tap kbd');
const pause = $('#pause');
let current = 0;
let run = 0; // Starting a new run cancels the old one.
let paused = reduceMotion;
let visible = true;

async function wait(ms) {
  await new Promise(resolve => setTimeout(resolve, ms));
  while (paused || !visible || document.hidden) await new Promise(resolve => setTimeout(resolve, 200));
}

function choose(index) {
  current = index;
  menu.src = `assets/shots/${demos[index].menu}-light.webp`;
  $$('[data-demo]').forEach(b => b.setAttribute('aria-pressed', Number(b.dataset.demo) === index));
}

/** The rewrite, with the changed words marked. */
function showChanges(before, after) {
  const a = before.split(' ');
  const b = after.split(' ');
  const common = Array.from({ length: a.length + 1 }, () => Array(b.length + 1).fill(0));
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      common[i][j] = a[i] === b[j] ? common[i + 1][j + 1] + 1 : Math.max(common[i + 1][j], common[i][j + 1]);
    }
  }
  const nodes = [];
  let i = 0;
  let j = 0;
  while (j < b.length) {
    if (i < a.length && a[i] === b[j]) {
      nodes.push(`${b[j++]} `);
      i++;
    } else if (i < a.length && common[i + 1][j] >= common[i][j + 1]) {
      i++;
    } else {
      const mark = document.createElement('mark');
      mark.textContent = b[j++];
      nodes.push(mark, ' ');
    }
  }
  draft.replaceChildren(...nodes);
}

async function play(index, { typing = true } = {}) {
  const id = ++run;
  const live = () => id === run;
  choose(index);
  const demo = demos[index];
  keys.forEach(key => key.classList.remove('down'));

  if (reduceMotion) {
    stage.dataset.phase = 'done';
    showChanges(demo.before, demo.after);
    return;
  }
  if (typing) {
    stage.dataset.phase = 'typing';
    for (let n = 0; n <= demo.before.length; n += 2) {
      draft.textContent = demo.before.slice(0, n);
      await wait(30);
      if (!live()) return;
    }
  }
  draft.textContent = demo.before;
  stage.dataset.phase = 'ready';
  await wait(450);
  if (!live()) return;
  for (const key of keys) {
    key.classList.add('down');
    await wait(130);
    key.classList.remove('down');
    if (!live()) return;
    await wait(90);
  }
  if (!live()) return;
  stage.dataset.phase = 'menu';
  await wait(1900);
  if (!live()) return;
  stage.dataset.phase = 'working';
  await wait(1000);
  if (!live()) return;
  stage.dataset.phase = 'done';
  showChanges(demo.before, demo.after);
  await wait(4200);
  if (live()) play((index + 1) % demos.length);
}

function setPaused(value) {
  paused = value;
  pause.textContent = value ? 'Play' : 'Pause';
  pause.setAttribute('aria-pressed', value);
}

function start(index) {
  setPaused(false);
  play(index, { typing: false });
}

$$('[data-demo]').forEach(b => b.addEventListener('click', () => start(Number(b.dataset.demo))));
$('#tap').addEventListener('click', () => start(current));
pause.hidden = reduceMotion;
pause.addEventListener('click', () => setPaused(!paused));

let lastTap = -Infinity;
addEventListener('keydown', event => {
  if (event.code !== 'AltRight') {
    lastTap = -Infinity;
    return;
  }
  if (event.repeat) return;
  if (event.timeStamp - lastTap < 400) {
    lastTap = -Infinity;
    stage.scrollIntoView({ block: 'center', behavior: reduceMotion ? 'auto' : 'smooth' });
    start(current);
  } else {
    lastTap = event.timeStamp;
  }
});

new IntersectionObserver(([entry]) => { visible = entry.isIntersecting }).observe(stage);
// The first frame is complete, so let it be seen before the loop starts.
if (!reduceMotion) setTimeout(() => { if (run === 0) play(0) }, 1800);

// The gallery
function replay(film) {
  film.classList.remove('play');
  void film.offsetWidth; // Restarts the CSS animations.
  film.classList.add('play');
}

const onFirstSight = new IntersectionObserver(entries => {
  entries.filter(e => e.isIntersecting).forEach(({ target }) => {
    replay(target);
    onFirstSight.unobserve(target);
  });
}, { threshold: 0.6 });

$$('.card').forEach(card => {
  const film = $('.film', card);
  const takes = $$('.take', film);
  const picker = $('.takes', card);

  if (picker) {
    takes.forEach((take, index) => {
      const button = document.createElement('button');
      button.type = 'button';
      button.textContent = index + 1;
      button.setAttribute('aria-label', `Example ${index + 1}`);
      button.setAttribute('aria-pressed', index === 0);
      button.addEventListener('click', () => {
        takes.forEach((other, i) => { other.hidden = i !== index });
        [...picker.children].forEach((other, i) => other.setAttribute('aria-pressed', i === index));
        replay(film);
      });
      picker.append(button);
    });
  }

  film.addEventListener('pointerenter', event => { if (event.pointerType === 'mouse') replay(film) });
  film.addEventListener('click', () => {
    const big = document.createElement('div');
    big.className = film.className;
    big.innerHTML = film.innerHTML;
    $('#viewer-film').replaceChildren(big);
    $('#viewer').showModal();
    replay(big);
  });
  onFirstSight.observe(film);
});

const viewer = $('#viewer');
$('.close', viewer).addEventListener('click', () => viewer.close());
viewer.addEventListener('click', event => { if (event.target === viewer) viewer.close() });

// Screenshots follow the page's light or dark look.
const screens = {
  'profile': [1120, 1504, 'Writer Profile'],
  'learning': [1120, 1344, 'What Nudge Learned'],
  'off-list': [920, 1084, 'Where Nudge Is Off'],
  'try-it': [1040, 636, 'Welcome'],
};
let screenName = 'profile';

function showScreen() {
  const [width, height, title] = screens[screenName];
  Object.assign($('#screen'), {
    width,
    height,
    src: `assets/shots/${screenName}-${isDark() ? 'dark' : 'light'}.webp`,
    alt: `Nudge ${title} window`,
  });
}

$$('[data-screen]').forEach(button => button.addEventListener('click', () => {
  screenName = button.dataset.screen;
  $$('[data-screen]').forEach(b => b.setAttribute('aria-pressed', b === button));
  showScreen();
}));

$('#theme').addEventListener('click', () => {
  const next = isDark() ? 'light' : 'dark';
  document.documentElement.dataset.theme = next;
  try { localStorage.setItem('theme', next) } catch {}
  showScreen();
});
systemDark.addEventListener('change', showScreen);
showScreen();
