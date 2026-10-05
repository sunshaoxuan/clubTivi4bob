const assert = require("node:assert/strict");
const path = require("node:path");
const fs = require("node:fs/promises");
const { chromium } = require("playwright");
const sharp = require("sharp");

const base = process.env.BOBTV_PREVIEW_URL || "http://127.0.0.1:8924/new/";
const output = path.resolve(__dirname, "../.capture/new-preview");
const viewports = [
  [1920, 1080],
  [1440, 960],
  [1024, 768],
  [768, 1024],
  [390, 844],
  [320, 667],
];
async function sceneFrame(page, width) {
  const rect = await page.locator("#scene").boundingBox();
  const mobile = width <= 700;
  return page.screenshot({
    clip: {
      x: rect.x + rect.width * (mobile ? 0.02 : 0.44),
      y: rect.y + rect.height * (mobile ? 0.53 : 0.16),
      width: rect.width * (mobile ? 0.96 : 0.53),
      height: rect.height * (mobile ? 0.3 : 0.64),
    },
  });
}

(async () => {
  await fs.mkdir(output, { recursive: true });
  const browser = await chromium.launch({
    headless: true,
    args: ["--enable-unsafe-swiftshader"],
    executablePath:
      process.env.CHROME_PATH ||
      (process.platform === "win32"
        ? "C:/Program Files/Google/Chrome/Application/chrome.exe"
        : undefined),
  });
  const results = [];
  try {
    for (const [width, height] of viewports) {
      const page = await browser.newPage({ viewport: { width, height } });
      const issues = [];
      page.on("pageerror", (e) => issues.push(e.message));
      page.on("console", (m) => {
        if (["error", "warning"].includes(m.type())) issues.push(m.text());
      });
      page.on("response", (r) => {
        if (r.status() >= 400) issues.push(r.status() + " " + r.url());
      });
      await page.goto(base);
      await page.waitForSelector("#scene.ready");
      await page.waitForFunction(() =>
        [...document.querySelectorAll(".hero-copy > *")].every(
          (e) => getComputedStyle(e).opacity === "1",
        ),
      );
      const layout = await page.evaluate(() => {
        const cta = document
          .querySelector(".primary-link")
          .getBoundingClientRect();
        const note = document
          .querySelector(".platform-note")
          .getBoundingClientRect();
        const strip = document
          .querySelector(".intro-strip")
          .getBoundingClientRect();
        return {
          overflow: document.documentElement.scrollWidth > innerWidth,
          ctaGap: note.top - cta.bottom,
          nextSection: strip.top < innerHeight,
        };
      });
      assert.equal(layout.overflow, false, width + ": horizontal overflow");
      assert.ok(layout.ctaGap >= 8, width + ": download copy overlaps");
      assert.equal(
        layout.nextSection,
        true,
        width + ": next section missing from first viewport",
      );
      const pixels = await sharp(await sceneFrame(page, width)).stats();
      assert.ok(pixels.channels[0].stdev > 15, width + ": blank scene");
      await page.screenshot({ path: path.join(output, width + ".png") });
      await page.getByRole("button", { name: "暂停动画", exact: true }).click();
      await page.locator('[data-channel="1"]').click();
      assert.equal(
        await page.locator("#scene").getAttribute("data-channel"),
        "1",
      );
      const pausedA = await sceneFrame(page, width);
      await page.waitForTimeout(250);
      const pausedB = await sceneFrame(page, width);
      assert.equal(
        pausedA.equals(pausedB),
        true,
        width + ": pause still animates",
      );
      await page.getByRole("button", { name: "播放动画", exact: true }).click();
      const movingA = await sceneFrame(page, width);
      await page.waitForTimeout(350);
      const movingB = await sceneFrame(page, width);
      assert.equal(
        movingA.equals(movingB),
        false,
        width + ": animation not moving",
      );
      await page.locator("#tab-favorites").click();
      assert.equal(
        await page.locator("#chapter-panel h3").textContent(),
        "喜欢的台，随时回来。",
      );
      await page.locator("#tab-favorites").press("ArrowRight");
      assert.equal(
        await page.locator("#tab-fullscreen").getAttribute("aria-selected"),
        "true",
      );
      assert.equal(
        await page.locator("#chapter-panel").getAttribute("aria-labelledby"),
        "tab-fullscreen",
      );
      await page.locator("#features").scrollIntoViewIfNeeded();
      await page.waitForTimeout(850);
      await page.screenshot({
        path: path.join(output, width + "-features.png"),
      });
      assert.equal(
        await page.evaluate(
          () => document.documentElement.scrollWidth > innerWidth,
        ),
        false,
      );
      assert.deepEqual(issues, [], width + ": browser diagnostics");
      results.push({
        width,
        height,
        layout,
        consoleAndNetworkIssues: issues.length,
        canvasNonblank: true,
        animated: true,
        pause: true,
        tabs: true,
      });
      await page.close();
    }
    const reduced = await browser.newPage({
      viewport: { width: 390, height: 844 },
      reducedMotion: "reduce",
    });
    await reduced.goto(base);
    await reduced.waitForSelector("#scene.ready");
    assert.equal(
      await reduced.locator(".motion-button").getAttribute("aria-pressed"),
      "true",
    );
    const stillA = await reduced.locator("canvas").screenshot();
    await reduced.waitForTimeout(300);
    assert.equal(
      stillA.equals(await reduced.locator("canvas").screenshot()),
      true,
      "reduced motion must be still",
    );
    await reduced.close();
    const fallback = await browser.newPage({
      viewport: { width: 390, height: 844 },
    });
    await fallback.addInitScript(() => {
      const getContext = HTMLCanvasElement.prototype.getContext;
      HTMLCanvasElement.prototype.getContext = function (type, ...args) {
        return type.startsWith("webgl")
          ? null
          : getContext.call(this, type, ...args);
      };
    });
    await fallback.goto(base);
    await fallback.waitForSelector('#scene[data-renderer="fallback"]');
    assert.equal(await fallback.locator(".scene-fallback").isVisible(), true);
    assert.equal(await fallback.locator(".motion-button").isDisabled(), true);
    await fallback.locator("#tab-favorites").click();
    assert.equal(
      await fallback.locator("#chapter-panel h3").textContent(),
      "喜欢的台，随时回来。",
    );
    await fallback.screenshot({ path: path.join(output, "fallback.png") });
    await fallback.close();
    const lost = await browser.newPage();
    await lost.goto(base);
    await lost.waitForSelector("#scene.ready");
    await lost
      .locator("canvas")
      .evaluate((c) =>
        c.getContext("webgl2").getExtension("WEBGL_lose_context").loseContext(),
      );
    await lost.waitForSelector('#scene[data-renderer="fallback"]');
    assert.equal(await lost.locator(".scene-fallback").isVisible(), true);
    assert.equal(await lost.locator('[data-channel="1"]').isDisabled(), true);
    await lost.close();
    console.log(
      JSON.stringify(
        {
          base,
          results,
          reducedMotion: "passed",
          webglUnavailable: "passed",
          webglContextLost: "passed",
        },
        null,
        2,
      ),
    );
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
