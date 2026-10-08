// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include HTML utilities to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/hermit";
import topbar from "../vendor/topbar";
import QRCode from "../vendor/qrcode";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const Hooks = {
  Flash: {
    mounted() {
      this.startTimer();
    },
    updated() {
      this.startTimer();
    },
    destroyed() {
      this.clearTimer();
    },
    startTimer() {
      this.clearTimer();
      const closeAfterAttr = this.el.getAttribute("data-close-after");
      let closeAfter = null;

      if (closeAfterAttr !== null) {
        if (closeAfterAttr !== "false" && closeAfterAttr !== "") {
          const parsed = parseInt(closeAfterAttr, 10);
          if (!isNaN(parsed) && parsed > 0) {
            closeAfter = parsed;
          }
        }
      } else if (this.el.id && this.el.id.startsWith("flash-")) {
        closeAfter = 5000;
      }

      if (closeAfter !== null) {
        this.timer = setTimeout(() => {
          const phxClick = this.el.getAttribute("phx-click");
          if (phxClick) {
            this.liveSocket.execJS(this.el, phxClick);
          } else {
            this.el.click();
          }
        }, closeAfter);
      }
    },
    clearTimer() {
      if (this.timer) {
        clearTimeout(this.timer);
        this.timer = null;
      }
    },
  },
  LocalTime: {
    mounted() {
      this.format();
    },
    updated() {
      this.format();
    },
    format() {
      const timestamp = this.el.getAttribute("data-timestamp");
      if (timestamp) {
        const date = new Date(parseInt(timestamp) * 1000);
        const pad = (num) => String(num).padStart(2, "0");
        this.el.textContent = `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
      }
    }
  },
  Clipboard: {
    mounted() {
      this.init();
    },
    updated() {
      this.init();
    },
    init() {
      if (this.el._clipboardInitialized) return;
      this.el._clipboardInitialized = true;

      this.el.addEventListener("click", (e) => {
        e.preventDefault();
        const text = this.el.getAttribute("data-clipboard-text");

        if (text) {
          navigator.clipboard.writeText(text).then(() => {
            const feedbackEl = this.el.querySelector(".copy-feedback");
            this.el.classList.add("text-emerald-500");

            if (feedbackEl) {
              const prev = feedbackEl.textContent;
              feedbackEl.textContent = this.el.getAttribute("data-copied-text") || "Copied!";
              feedbackEl.classList.remove("hidden");
              setTimeout(() => {
                feedbackEl.textContent = prev;
                this.el.classList.remove("text-emerald-500");
              }, 2000);
            }

            const existingToast = document.getElementById("clipboard-toast");
            if (existingToast) existingToast.remove();

            const toast = document.createElement("div");
            toast.id = "clipboard-toast";
            toast.className =
              "fixed bottom-5 right-5 z-50 flex items-center gap-2 bg-base-100 border border-emerald-500/30 text-emerald-500 px-3.5 py-2 rounded-[10px] shadow-xl text-xs font-medium";
            toast.innerHTML = `
              <svg class="size-4 shrink-0 text-emerald-500" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" d="m4.5 12.75 6 6 9-13.5" />
              </svg>
              <span>Copied to clipboard!</span>
            `;
            document.body.appendChild(toast);
            setTimeout(() => {
              toast.style.opacity = "0";
              toast.style.transition = "opacity 0.3s ease";
              setTimeout(() => toast.remove(), 300);
            }, 1800);
          });
        }
      });
    }
  },
  QRCode: {
    mounted() {
      this.render();
    },
    updated() {
      this.render();
    },
    render() {
      const text = this.el.getAttribute("data-qr-content");
      const size = parseInt(this.el.getAttribute("data-qr-size") || "110", 10);
      if (text && QRCode && QRCode.drawCanvas) {
        try {
          QRCode.drawCanvas(this.el, text, size);
        } catch (e) {
          console.error("Local QRCode error:", e);
        }
      }
    }
  },
  ThemeToggle: {
    mounted() {
      this.el.addEventListener("click", () => {
        const current =
          document.documentElement.getAttribute("data-theme") || "light";
        const next = current === "dark" ? "light" : "dark";
        document.documentElement.setAttribute("data-theme", next);
        localStorage.setItem("hermit_theme", next);
      });
    }
  }
};

// Initialize theme from localStorage or system preference
const savedTheme =
  localStorage.getItem("hermit_theme") ||
  (window.matchMedia("(prefers-color-scheme: dark)").matches
    ? "dark"
    : "light");
document.documentElement.setAttribute("data-theme", savedTheme);

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: { ...Hooks, ...colocatedHooks },
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

// The lines below enable quality of life live reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener(
    "phx:live_reload:attached",
    ({ detail: reloader }) => {
      // Enable server log streaming to client.
      // Disable with reloader.disableServerLogs()
      reloader.enableServerLogs();

      // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
      //
      //   * click with "c" key pressed to open at caller location
      //   * click with "d" key pressed to open at function component definition location
      let keyDown;
      window.addEventListener("keydown", (e) => (keyDown = e.key));
      window.addEventListener("keyup", (_e) => (keyDown = null));
      window.addEventListener(
        "click",
        (e) => {
          if (keyDown === "c") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtCaller(e.target);
          } else if (keyDown === "d") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtDef(e.target);
          }
        },
        true,
      );

      window.liveReloader = reloader;
    },
  );
}
