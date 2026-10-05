import { createScene } from "./scene.js";

const gsap = window.gsap;
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
const motionButton = document.querySelector(".motion-button");
window.lucide?.createIcons();
let paused = reducedMotion.matches;
let scene;

function motionState() {
  motionButton.setAttribute("aria-pressed", String(paused));
  motionButton.setAttribute("aria-label", paused ? "播放动画" : "暂停动画");
  motionButton.title = paused ? "播放动画" : "暂停动画";
  motionButton.innerHTML =
    '<i data-lucide="' + (paused ? "play" : "pause") + '"></i>';
  window.lucide?.createIcons({ root: motionButton });
  scene?.setPaused(paused);
}
motionState();
motionButton.addEventListener("click", () => {
  paused = !paused;
  motionState();
});
reducedMotion.addEventListener("change", () => {
  paused = reducedMotion.matches;
  motionState();
});
const channelButtons = [...document.querySelectorAll("[data-channel]")];
let requestedChannel = 0;
function unavailable() {
  channelButtons.forEach((button) => {
    button.disabled = true;
  });
  motionButton.disabled = true;
}
document
  .querySelector("#scene")
  .addEventListener("sceneunavailable", unavailable);
function onChannel(index) {
  channelButtons.forEach((button, i) =>
    button.setAttribute("aria-pressed", String(i === index)),
  );
}
channelButtons.forEach((button) =>
  button.addEventListener("click", () => {
    const index = Number(button.dataset.channel);
    requestedChannel = index;
    onChannel(index);
    scene?.select(index);
  }),
);
try {
  scene = await createScene(document.querySelector("#scene"), {
    paused,
    onChannel,
  });
  scene.select(requestedChannel, false);
  scene.setPaused(paused);
} catch {
  // The real product image remains visible when WebGL or a texture is unavailable.
  document.querySelector("#scene").dataset.renderer = "fallback";
  unavailable();
}

const chapters = [
  [
    "切台之前，心里有数。",
    "点选频道，先在卡片里静音预览。再次点选切到主播放器，也可以双击直接切换。正在看的节目，始终留在眼前。",
  ],
  [
    "喜欢的台，随时回来。",
    "在频道或播放器菜单中加入收藏。常看的节目聚在一起，音量与频道操作保持顺手，下一次打开也容易找到。",
  ],
  [
    "让节目，占满视野。",
    "进入全屏后，闲置光标自动隐藏。双击回到打开播放的界面；Windows 顶部窗口控制可通过鼠标唤出。",
  ],
];
const tabs = [...document.querySelectorAll("[data-chapter]")];
const panel = document.querySelector("#chapter-panel");
function selectChapter(index) {
  tabs.forEach((tab, i) => {
    tab.setAttribute("aria-selected", String(i === index));
    tab.tabIndex = i === index ? 0 : -1;
  });
  panel.setAttribute("aria-labelledby", tabs[index].id);
  panel.querySelector("h3").textContent = chapters[index][0];
  panel.querySelector("p").textContent = chapters[index][1];
  if (gsap && !reducedMotion.matches)
    gsap.fromTo(
      panel,
      { opacity: 0.35, y: 8 },
      { opacity: 1, y: 0, duration: 0.35, overwrite: true },
    );
}
tabs.forEach((tab, index) => {
  tab.addEventListener("click", () => selectChapter(index));
  tab.addEventListener("keydown", (event) => {
    const keys = [
      "ArrowRight",
      "ArrowDown",
      "ArrowLeft",
      "ArrowUp",
      "Home",
      "End",
    ];
    if (!keys.includes(event.key)) return;
    event.preventDefault();
    let next =
      event.key === "Home"
        ? 0
        : event.key === "End"
          ? tabs.length - 1
          : (index +
              (["ArrowRight", "ArrowDown"].includes(event.key) ? 1 : -1) +
              tabs.length) %
            tabs.length;
    selectChapter(next);
    tabs[next].focus();
  });
});

let media;
if (gsap && window.ScrollTrigger) {
  gsap.registerPlugin(window.ScrollTrigger);
  media = gsap.matchMedia();
  media.add("(prefers-reduced-motion: no-preference)", () => {
    gsap.from(".hero-copy > p, .hero-copy > h1", {
      y: 18,
      opacity: 0,
      stagger: 0.09,
      duration: 0.8,
      ease: "power3.out",
    });
    gsap.from(".hero-copy > a", {
      opacity: 0,
      duration: 0.8,
      ease: "power3.out",
    });
    gsap.fromTo(
      ".player-media",
      { rotationX: 7, scale: 0.94 },
      {
        rotationX: 0,
        scale: 1,
        ease: "none",
        scrollTrigger: {
          trigger: ".player-stage",
          start: "top 95%",
          end: "center 60%",
          scrub: 0.7,
        },
      },
    );
    document
      .querySelectorAll(".section h2, .detail-grid article, .frequency-row")
      .forEach((element) => {
        gsap.from(element, {
          y: 24,
          opacity: 0,
          duration: 0.7,
          ease: "power3.out",
          scrollTrigger: { trigger: element, start: "top 94%", once: true },
        });
      });
    if (scene)
      gsap.to(scene.scrollState, {
        progress: 1,
        ease: "none",
        onUpdate: scene.render,
        scrollTrigger: {
          trigger: ".hero",
          start: "top top",
          end: "bottom top",
          scrub: 0.5,
        },
      });
  });
}
window.addEventListener("pagehide", (event) => {
  if (!event.persisted) {
    media?.revert();
    scene?.dispose();
  }
});
