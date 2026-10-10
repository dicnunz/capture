"use strict";
const $ = (id) => document.getElementById(id);
if (new URLSearchParams(location.search).has("backdrop")) document.body.dataset.backdrop = "true";
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
let background;
let audioContext;
let oscillator;
let gain;
let startingTone = false;
let toneGeneration = 0;
let mediaURL;
let lastFile;

const stories = {
  audio: ["01 / APP AUDIO", "Only the sound<br>you choose.", "Play a soft test tone. Choose this app as Capture’s audio source."],
  copy: ["02 / COPY SCREENSHOT", "Select. Copy.<br>Paste.", "Choose an area with Capture. Copy it, then paste it below."],
  finish: ["03 / FINISH & PREVIEW", "Stop and see<br>the result.", "Record this scene with Capture. Open the saved video to play it here."],
  result: ["04 / RESULT", "Your capture,<br>ready to use.", "Open a real screenshot or recording from this Mac. Nothing is uploaded."]
};

function setScene(scene) {
  document.body.dataset.scene = scene;
  document.querySelectorAll("[data-scene-choice]").forEach((button) => button.setAttribute("aria-pressed", String(button.dataset.sceneChoice === scene)));
  if (background) background.destroy();
  try {
    const common = { el: "#ambient", THREE, mouseControls: false, touchControls: false, gyroControls: false, minHeight: 200, minWidth: 200, scale: 1, scaleMobile: 1 };
    background = scene === "waves"
      ? VANTA.WAVES({ ...common, color: 0x0b454c, shininess: 25, waveHeight: 13, waveSpeed: reducedMotion ? 0 : .28, zoom: .78 })
      : VANTA.FOG({ ...common, highlightColor: 0xfaf0c6, midtoneColor: 0xdcc3a1, lowlightColor: 0xb5aca2, baseColor: 0xf1e8d8, blurFactor: .6, speed: reducedMotion ? 0 : .32, zoom: .8 });
  } catch (error) {
    $("file-status").textContent = "The animated background is unavailable on this browser.";
    console.warn("WebGL background unavailable", error);
  }
}

function setFeature(feature) {
  if (feature !== "audio") stopTone();
  document.body.dataset.feature = feature;
  const [step, title, description] = stories[feature];
  $("feature-step").textContent = step;
  $("feature-title").innerHTML = title;
  $("feature-description").textContent = description;
  document.querySelectorAll("[data-feature-choice]").forEach((button) => {
    if (button.dataset.featureChoice === feature) button.setAttribute("aria-current", "step");
    else button.removeAttribute("aria-current");
  });
  document.querySelector(".actions").hidden = feature !== "audio";
  document.querySelector(".result-actions").hidden = !["finish", "result"].includes(feature);
  $("paste-area").hidden = !["copy", "result"].includes(feature);
  $("file-status").textContent = "";
  if (feature === "result" && lastFile) showMedia(lastFile);
}

async function startTone() {
  if (oscillator || startingTone) return;
  startingTone = true;
  const generation = ++toneGeneration;
  $("tone-start").disabled = true;
  try {
    audioContext ||= new (window.AudioContext || window.webkitAudioContext)();
    await audioContext.resume();
    if (generation !== toneGeneration) return;
    gain = audioContext.createGain();
    gain.gain.setValueAtTime(0, audioContext.currentTime);
    gain.gain.linearRampToValueAtTime(.045, audioContext.currentTime + .2);
    oscillator = audioContext.createOscillator();
    oscillator.type = "sine";
    oscillator.frequency.value = 660;
    oscillator.connect(gain);
    gain.connect(audioContext.destination);
    oscillator.start();
    $("tone-start").disabled = true;
    $("tone-stop").disabled = false;
    $("tone-state").textContent = "660 Hz playing";
  } catch (error) {
    $("tone-start").disabled = false;
    $("tone-state").textContent = "Audio unavailable";
    console.error(error);
  } finally {
    startingTone = false;
  }
}

function stopTone() {
  toneGeneration++;
  if (oscillator && audioContext) {
    const ending = oscillator;
    const fading = gain;
    const now = audioContext.currentTime;
    fading.gain.cancelScheduledValues(now);
    fading.gain.setValueAtTime(fading.gain.value, now);
    fading.gain.linearRampToValueAtTime(0, now + .08);
    ending.stop(now + .1);
    ending.onended = () => { ending.disconnect(); fading.disconnect(); };
    oscillator = undefined;
  }
  $("tone-start").disabled = false;
  $("tone-stop").disabled = true;
  $("tone-state").textContent = "Muted";
}

function releaseMedia() {
  const video = $("media-container").querySelector("video");
  if (video) { video.pause(); video.removeAttribute("src"); video.load(); }
  $("media-container").replaceChildren();
  if (mediaURL) URL.revokeObjectURL(mediaURL);
  mediaURL = undefined;
}

function showMedia(file) {
  if (!file.type.startsWith("image/") && !file.type.startsWith("video/")) {
    $("file-status").textContent = "Choose an image or a video file.";
    return;
  }
  stopTone();
  releaseMedia();
  lastFile = file;
  mediaURL = URL.createObjectURL(file);
  const video = file.type.startsWith("video/");
  const element = document.createElement(video ? "video" : "img");
  element.src = mediaURL;
  if (video) {
    element.controls = true;
    element.preload = "metadata";
    element.playsInline = true;
    element.onloadedmetadata = () => { element.pause(); $("media-info").textContent = `${element.videoWidth} × ${element.videoHeight} · ${element.duration.toFixed(1)} s`; };
  } else {
    element.alt = "Actual captured screenshot";
    element.onload = () => { $("media-info").textContent = `${element.naturalWidth} × ${element.naturalHeight}`; };
  }
  element.onerror = () => { $("media-info").textContent = "This file could not be previewed."; };
  $("media-info").textContent = "";
  $("media-name").textContent = file.name || (video ? "Captured video" : "Pasted screenshot");
  $("media-container").append(element);
  $("media-view").hidden = false;
  $("media-back").focus();
}

function closeMedia() {
  releaseMedia();
  $("media-view").hidden = true;
  document.querySelector(`[data-feature-choice="${document.body.dataset.feature}"]`).focus();
}

document.querySelectorAll("[data-scene-choice]").forEach((button) => button.addEventListener("click", () => setScene(button.dataset.sceneChoice)));
document.querySelectorAll("[data-feature-choice]").forEach((button) => button.addEventListener("click", () => setFeature(button.dataset.featureChoice)));
$("tone-start").addEventListener("click", startTone);
$("tone-stop").addEventListener("click", stopTone);
$("open-image").addEventListener("click", () => $("image-file").click());
$("open-video").addEventListener("click", () => $("video-file").click());
[$("image-file"), $("video-file")].forEach((input) => input.addEventListener("change", () => { if (input.files[0]) showMedia(input.files[0]); input.value = ""; }));
$("media-back").addEventListener("click", closeMedia);
$("paste-area").addEventListener("paste", (event) => {
  const image = Array.from(event.clipboardData?.items || []).find((item) => item.type.startsWith("image/"));
  if (image) { event.preventDefault(); const file = image.getAsFile(); if (file) showMedia(file); }
});
document.addEventListener("keydown", (event) => { if (event.key === "Escape" && !$("media-view").hidden) closeMedia(); });
window.addEventListener("pagehide", stopTone);
setScene("waves");
