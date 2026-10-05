import * as THREE from "three";
import { RoundedBoxGeometry } from "three/addons/geometries/RoundedBoxGeometry.js";
import { RoomEnvironment } from "three/addons/environments/RoomEnvironment.js";

export async function createScene(container, { paused, onChannel }) {
  const gsap = window.gsap;
  if (!gsap) throw new Error("Animation library unavailable");
  const renderer = new THREE.WebGLRenderer({
    antialias: true,
    alpha: true,
    powerPreference: "low-power",
  });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 1.75));
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.05;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(32, 1, 0.1, 60);
  const pmrem = new THREE.PMREMGenerator(renderer);
  const room = new RoomEnvironment();
  const environment = pmrem.fromScene(room, 0.04);
  scene.environment = environment.texture;
  room.dispose();
  pmrem.dispose();
  const resources = new Set();
  const own = (resource) => {
    resources.add(resource);
    return resource;
  };
  const mat = (color, roughness = 0.35, metalness = 0.25) =>
    own(new THREE.MeshStandardMaterial({ color, roughness, metalness }));
  const shell = mat("#101210", 0.3, 0.65);
  const bevel = mat("#565952", 0.24, 0.85);
  const graphite = mat("#141613", 0.38, 0.35);
  const red = mat("#ff3328", 0.26, 0.35);
  red.emissive.set("#9e0601");
  red.emissiveIntensity = 0.15;
  red.toneMapped = false;
  const pale = mat("#c1c8b8", 0.3, 0.6);
  const device = new THREE.Group();
  scene.add(device);
  function box(w, h, d, material, radius = 0.1, parent = device) {
    const mesh = new THREE.Mesh(
      own(new RoundedBoxGeometry(w, h, d, 3, radius)),
      material,
    );
    mesh.castShadow = true;
    mesh.receiveShadow = true;
    parent.add(mesh);
    return mesh;
  }
  function text(label, w, h, size = 50, color = "#d1d5c9", parent = device) {
    const canvas = document.createElement("canvas");
    canvas.width = 1024;
    canvas.height = 128;
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = color;
    ctx.font = "500 " + size + "px Arial, Microsoft YaHei, sans-serif";
    ctx.textBaseline = "middle";
    ctx.fillText(label, 12, 64);
    const texture = own(new THREE.CanvasTexture(canvas));
    texture.colorSpace = THREE.SRGBColorSpace;
    const mesh = new THREE.Mesh(
      own(new THREE.PlaneGeometry(w, h)),
      own(
        new THREE.MeshBasicMaterial({
          map: texture,
          transparent: true,
          depthWrite: false,
          toneMapped: false,
        }),
      ),
    );
    parent.add(mesh);
    return mesh;
  }
  box(6.3, 4.25, 0.32, bevel, 0.2).position.z = -0.02;
  box(6.23, 4.18, 0.35, shell, 0.2).position.z = 0.02;
  box(6.02, 3.97, 0.12, graphite, 0.14).position.z = 0.2;
  text("BoBTV", 1.1, 0.14, 66).position.set(-2.34, 1.78, 0.29);
  text("DESKTOP TELEVISION", 1.75, 0.11, 40, "#959c8a").position.set(
    0.83,
    1.78,
    0.29,
  );
  const led = new THREE.Mesh(own(new THREE.SphereGeometry(0.035, 16, 16)), red);
  led.position.set(2.7, 1.79, 0.32);
  device.add(led);
  box(5.67, 2.98, 0.11, mat("#090b09", 0.32, 0.6), 0.08).position.set(
    0,
    0.08,
    0.3,
  );
  let texture;
  try {
    texture = own(
      await new THREE.TextureLoader().loadAsync(
        new URL("./assets/product.png", import.meta.url).href,
      ),
    );
    if (!container.isConnected)
      throw new Error("Scene removed during initialization");
  } catch (error) {
    resources.forEach((resource) => resource.dispose());
    environment.dispose();
    renderer.dispose();
    throw error;
  }
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.anisotropy = Math.min(renderer.capabilities.getMaxAnisotropy(), 8);
  const display = new THREE.Mesh(
    own(new THREE.PlaneGeometry(5.5, 2.85)),
    own(new THREE.MeshBasicMaterial({ map: texture, toneMapped: false })),
  );
  display.position.set(0, 0.08, 0.37);
  device.add(display);
  const buttons = [];
  const outlines = [];
  ["SPORT", "CINEMA", "RADIO"].forEach((label, index) => {
    const group = new THREE.Group();
    group.position.set(-1.84 + index * 1.84, -1.7, 0.29);
    device.add(group);
    const outline = box(
      1.72,
      0.45,
      0.08,
      index === 0 ? red : shell,
      0.06,
      group,
    );
    outlines.push(outline);
    const button = box(1.66, 0.39, 0.11, graphite, 0.06, group);
    button.position.z = 0.035;
    button.userData.channel = index;
    buttons.push(button);
    text(label, 1.15, 0.1, 67, "#d1d5c9", group).position.set(0.07, 0, 0.1);
    const dot = new THREE.Mesh(
      own(new THREE.CylinderGeometry(0.034, 0.034, 0.024, 20)),
      index === 0 ? red : pale,
    );
    dot.rotation.x = Math.PI / 2;
    dot.position.set(-0.62, 0, 0.1);
    group.add(dot);
  });

  // An extruded pointer gives the reference's physical press-and-release motion.
  const cursorShape = new THREE.Shape();
  cursorShape.moveTo(0, 0);
  cursorShape.lineTo(0.14, -0.63);
  cursorShape.lineTo(0.29, -0.42);
  cursorShape.lineTo(0.54, -0.4);
  cursorShape.closePath();
  const cursor = new THREE.Group();
  device.add(cursor);
  const cursorMesh = new THREE.Mesh(
    own(
      new THREE.ExtrudeGeometry(cursorShape, {
        depth: 0.09,
        bevelEnabled: true,
        bevelSize: 0.035,
        bevelThickness: 0.035,
        bevelSegments: 3,
        steps: 1,
      }),
    ),
    bevel,
  );
  cursorMesh.castShadow = true;
  cursor.add(cursorMesh);
  const cursorFace = new THREE.Mesh(
    own(new THREE.ShapeGeometry(cursorShape)),
    graphite,
  );
  cursorFace.position.z = 0.13;
  cursor.add(cursorFace);
  cursor.rotation.z = -0.22;
  cursor.position.set(-1.75, -1.6, 1.1);

  const badge = new THREE.Group();
  device.add(badge);
  badge.position.set(2.45, -1.5, 0.85);
  const disc = new THREE.Mesh(
    own(new THREE.CylinderGeometry(0.26, 0.26, 0.14, 64)),
    red,
  );
  disc.rotation.x = Math.PI / 2;
  disc.castShadow = true;
  badge.add(disc);
  const play = new THREE.Shape();
  play.moveTo(-0.07, -0.11);
  play.lineTo(0.12, 0);
  play.lineTo(-0.07, 0.11);
  play.closePath();
  const playMesh = new THREE.Mesh(own(new THREE.ShapeGeometry(play)), pale);
  playMesh.position.z = 0.08;
  badge.add(playMesh);
  const cable = new THREE.Mesh(
    own(new THREE.TorusGeometry(0.35, 0.017, 10, 90)),
    bevel,
  );
  cable.position.z = -0.07;
  badge.add(cable);
  const wave = [];
  for (let i = 0; i < 13; i++) {
    const bar = box(
      0.035,
      0.1 + Math.sin(i * 0.7) ** 2 * 0.16,
      0.04,
      red,
      0.015,
    );
    bar.position.set(1.58 + i * 0.06, 1.79, 0.31);
    wave.push(bar);
  }
  const key = new THREE.DirectionalLight("#ffffff", 2.8);
  key.position.set(-3, 6, 7);
  key.castShadow = true;
  key.shadow.mapSize.set(1024, 1024);
  key.shadow.camera.left = -10;
  key.shadow.camera.right = 10;
  key.shadow.camera.top = 8;
  key.shadow.camera.bottom = -8;
  key.shadow.bias = -0.002;
  scene.add(key);
  const fill = new THREE.DirectionalLight("#f0f1ef", 1.5);
  fill.position.set(6, 1, 4);
  scene.add(fill);
  const rim = new THREE.DirectionalLight("#ff6a59", 1);
  rim.position.set(-5, 0, -2);
  scene.add(rim);
  const floor = new THREE.Mesh(
    own(new THREE.PlaneGeometry(100, 100)),
    own(new THREE.ShadowMaterial({ opacity: 0.25 })),
  );
  floor.rotation.x = -Math.PI / 2;
  floor.position.y = -3.3;
  floor.receiveShadow = true;
  scene.add(floor);
  const scrollState = { progress: 0 };
  const pointer = { x: 0, y: 0 };
  let running = !paused,
    visible = true,
    disposed = false,
    lost = false,
    manualUntil = 0,
    baseY = 0;
  let frame = 0,
    lastTime = 0,
    elapsed = 0;
  const loop = gsap.timeline({ repeat: -1, repeatDelay: 1.4, paused: true });
  for (let index = 0; index < 3; index++) {
    const x = -1.84 + index * 1.84;
    loop.to(cursor.position, {
      x,
      y: -1.63,
      z: 0.95,
      duration: 0.8,
      ease: "power3.inOut",
    });
    loop.to(cursor.position, { z: 0.5, duration: 0.2, ease: "power2.in" });
    loop.call(() => select(index, false));
    loop.to(cursor.position, {
      z: 0.95,
      duration: 0.65,
      ease: "back.out(2.5)",
    });
    loop.to({}, { duration: 1.05 });
  }
  function select(index, manual = true) {
    if (index < 0 || index > 2 || disposed || lost) return;
    onChannel(index);
    container.dataset.channel = String(index);
    outlines.forEach((outline, i) => {
      outline.material = i === index ? red : shell;
    });
    if (manual) manualUntil = performance.now() + 5000;
    if (running) {
      gsap.fromTo(
        buttons[index].position,
        { z: -0.025 },
        {
          z: 0.035,
          duration: 0.7,
          ease: "elastic.out(1,.35)",
          overwrite: true,
        },
      );
      gsap.fromTo(
        badge.scale,
        { x: 0.7, y: 0.7, z: 0.7 },
        {
          x: 1,
          y: 1,
          z: 1,
          duration: 0.65,
          ease: "back.out(2)",
          overwrite: true,
        },
      );
      gsap.fromTo(
        red,
        { emissiveIntensity: 0.4 },
        { emissiveIntensity: 0.15, duration: 0.6, overwrite: true },
      );
      if (manual) loop.pause();
    }
    draw();
  }
  function resize() {
    const { width, height } = container.getBoundingClientRect();
    const mobile = width <= 700;
    camera.aspect = width / height;
    camera.position.set(0, 0, mobile ? 18.5 : width <= 1100 ? 13.5 : 12.8);
    camera.updateProjectionMatrix();
    renderer.setPixelRatio(Math.min(devicePixelRatio, 1.75));
    renderer.setSize(width, height);
    const viewWidth =
      2 *
      camera.position.z *
      Math.tan(THREE.MathUtils.degToRad(16)) *
      camera.aspect;
    device.scale.setScalar(
      mobile
        ? Math.min(1, viewWidth / (height < 740 ? 8.8 : 7.4))
        : Math.min(1.3, (viewWidth * 0.47) / 6.3),
    );
    baseY = mobile ? (height < 740 ? -2.6 : -1.8) : -0.1;
    device.position.set(mobile ? 0 : viewWidth * 0.19, baseY, 0);
    draw();
  }
  function draw() {
    if (disposed || lost) return;
    const mobile = container.clientWidth <= 700;
    device.rotation.set(
      0.08 + pointer.y * 0.025 + scrollState.progress * 0.1,
      -0.15 + pointer.x * 0.035,
      -0.035,
    );
    device.position.z = -scrollState.progress * 1.2;
    if (running) {
      device.position.y = baseY + Math.sin(elapsed * 0.7) * 0.035;
      badge.position.z = 0.85 + Math.sin(elapsed * 1.6) * 0.1;
      badge.rotation.z = Math.sin(elapsed) * 0.08;
      wave.forEach((bar, i) => {
        bar.scale.y = 0.65 + Math.sin(elapsed * 3 + i * 0.6) ** 2 * 0.7;
      });
    }
    if (mobile) device.rotation.y *= 0.55;
    renderer.render(scene, camera);
  }
  function tick(time) {
    frame = 0;
    if (disposed || lost || !running || !visible || document.hidden) return;
    frame = requestAnimationFrame(tick);
    if (time - lastTime < 1000 / 45) return;
    elapsed += Math.min((time - lastTime) / 1000, 0.05);
    lastTime = time;
    if (running && performance.now() >= manualUntil && loop.paused())
      loop.resume();
    draw();
  }
  const raycaster = new THREE.Raycaster();
  function hit(event) {
    const rect = container.getBoundingClientRect();
    raycaster.setFromCamera(
      new THREE.Vector2(
        ((event.clientX - rect.left) / rect.width) * 2 - 1,
        (-(event.clientY - rect.top) / rect.height) * 2 + 1,
      ),
      camera,
    );
    return raycaster.intersectObjects(buttons)[0];
  }
  function pointerMove(event) {
    if (event.pointerType === "touch") return;
    const rect = container.getBoundingClientRect();
    pointer.x = (event.clientX - rect.left) / rect.width - 0.5;
    pointer.y = (event.clientY - rect.top) / rect.height - 0.5;
    container.style.cursor = hit(event) ? "pointer" : "default";
  }
  function click(event) {
    const target = hit(event);
    if (target) select(target.object.userData.channel);
  }
  function visibility() {
    if (disposed || lost) return;
    if (document.hidden || !visible || !running) {
      loop.pause();
      cancelAnimationFrame(frame);
      frame = 0;
    } else {
      if (performance.now() >= manualUntil) loop.resume();
      if (!frame) {
        lastTime = performance.now();
        frame = requestAnimationFrame(tick);
      }
    }
  }
  function contextLost(event) {
    event.preventDefault();
    lost = true;
    running = false;
    loop.pause();
    cancelAnimationFrame(frame);
    frame = 0;
    container.classList.remove("ready");
    container.dataset.renderer = "fallback";
    renderer.domElement.style.display = "none";
    container.dispatchEvent(new Event("sceneunavailable"));
  }
  container.addEventListener("pointermove", pointerMove);
  container.addEventListener("click", click);
  document.addEventListener("visibilitychange", visibility);
  renderer.domElement.addEventListener("webglcontextlost", contextLost);
  const observer = new ResizeObserver(resize);
  observer.observe(container);
  const intersection = new IntersectionObserver((entries) => {
    visible = entries[0].isIntersecting;
    visibility();
  });
  intersection.observe(container);
  container.append(renderer.domElement);
  resize();
  select(0, false);
  container.classList.add("ready");
  container.dataset.renderer = "webgl";
  if (running) loop.play();
  if (running && !frame) frame = requestAnimationFrame(tick);
  return {
    select,
    scrollState,
    render: draw,
    setPaused(value) {
      if (disposed || lost) return;
      running = !value;
      if (!running) {
        loop.pause();
        gsap.killTweensOf(red);
        red.emissiveIntensity = 0.15;
        buttons.forEach((button) => {
          gsap.killTweensOf(button.position);
          button.position.z = 0.035;
        });
        gsap.killTweensOf(badge.scale);
        badge.scale.set(1, 1, 1);
      }
      visibility();
      draw();
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      cancelAnimationFrame(frame);
      loop.kill();
      observer.disconnect();
      intersection.disconnect();
      container.removeEventListener("pointermove", pointerMove);
      container.removeEventListener("click", click);
      document.removeEventListener("visibilitychange", visibility);
      renderer.domElement.removeEventListener("webglcontextlost", contextLost);
      resources.forEach((resource) => {
        gsap.killTweensOf(resource);
        resource.dispose();
      });
      buttons.forEach((button) => gsap.killTweensOf(button.position));
      gsap.killTweensOf(badge.scale);
      gsap.killTweensOf(scrollState);
      environment.dispose();
      renderer.dispose();
      renderer.forceContextLoss();
      renderer.domElement.remove();
      container.classList.remove("ready");
    },
  };
}
