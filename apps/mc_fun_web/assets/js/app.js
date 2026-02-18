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

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/mc_fun_web"
import topbar from "../vendor/topbar"

// Custom LiveView hooks
const Hooks = {
  RconConsole: {
    mounted() {
      this.history = []
      this.historyIndex = -1
      this.draft = ""
      this.lastCommand = ""
      const input = this.el.querySelector("input[name='command']")
      if (!input) return

      input.addEventListener("keydown", (e) => {
        if (e.key === "Tab") {
          // Tab to repeat last command
          if (input.value.trim() === "" && this.lastCommand) {
            e.preventDefault()
            input.value = this.lastCommand
            this.pushEvent("rcon_input", {command: input.value})
          }
        } else if (e.key === "ArrowUp") {
          e.preventDefault()
          if (this.historyIndex === -1) this.draft = input.value
          if (this.historyIndex < this.history.length - 1) {
            this.historyIndex++
            input.value = this.history[this.historyIndex]
            this.pushEvent("rcon_input", {command: input.value})
          }
        } else if (e.key === "ArrowDown") {
          e.preventDefault()
          if (this.historyIndex > 0) {
            this.historyIndex--
            input.value = this.history[this.historyIndex]
            this.pushEvent("rcon_input", {command: input.value})
          } else if (this.historyIndex === 0) {
            this.historyIndex = -1
            input.value = this.draft
            this.pushEvent("rcon_input", {command: input.value})
          }
        }
      })

      this.el.addEventListener("submit", () => {
        const cmd = input.value.trim()
        if (cmd) {
          this.lastCommand = cmd
          if (this.history.length === 0 || this.history[0] !== cmd) {
            this.history.unshift(cmd)
            if (this.history.length > 50) this.history.pop()
          }
        }
        this.historyIndex = -1
        this.draft = ""
      })
    }
  },
  QuickCommands: {
    mounted() {
      this.el.addEventListener("submit", (e) => {
        const form = e.target.closest("form")
        if (form) setTimeout(() => form.reset(), 50)
      })
    }
  },
  WorldMap: (() => {
    // Static block color map — built once, shared across all instances
    const BLOCK_COLORS = {
      grass_block: [86, 140, 60],
      short_grass: [76, 130, 50],
      tall_grass: [76, 130, 50],
      dirt: [134, 96, 67],
      stone: [128, 128, 128],
      cobblestone: [120, 120, 120],
      deepslate: [80, 80, 85],
      water: [50, 90, 180],
      sand: [219, 207, 163],
      gravel: [140, 133, 126],
      oak_log: [109, 85, 50],
      spruce_log: [58, 37, 16],
      birch_log: [216, 210, 192],
      jungle_log: [87, 67, 27],
      dark_oak_log: [60, 46, 26],
      oak_leaves: [58, 95, 22],
      spruce_leaves: [42, 75, 42],
      birch_leaves: [68, 105, 38],
      jungle_leaves: [45, 90, 15],
      dark_oak_leaves: [38, 72, 18],
      oak_planks: [162, 131, 78],
      snow: [240, 240, 255],
      snow_block: [240, 240, 255],
      powder_snow: [235, 235, 250],
      ice: [145, 190, 230],
      packed_ice: [130, 170, 215],
      blue_ice: [100, 150, 230],
      clay: [160, 166, 179],
      terracotta: [152, 94, 67],
      sandstone: [216, 203, 155],
      red_sand: [190, 100, 50],
      red_sandstone: [186, 99, 44],
      netherrack: [100, 38, 38],
      end_stone: [220, 220, 170],
      obsidian: [20, 18, 30],
      bedrock: [50, 50, 50],
      iron_ore: [150, 140, 130],
      coal_ore: [80, 80, 80],
      gold_ore: [160, 150, 80],
      diamond_ore: [100, 200, 210],
      lapis_ore: [50, 70, 160],
      redstone_ore: [150, 40, 40],
      emerald_ore: [50, 180, 80],
      copper_ore: [130, 100, 70],
      andesite: [136, 136, 136],
      diorite: [188, 188, 188],
      granite: [153, 114, 99],
      tuff: [108, 109, 102],
      mycelium: [111, 99, 107],
      podzol: [122, 89, 45],
      farmland: [110, 75, 45],
      dirt_path: [148, 130, 82],
      moss_block: [80, 120, 50],
      mud: [60, 55, 50],
      lava: [207, 92, 15],
    }
    const DEFAULT_COLOR = [100, 100, 100]

    return {
    mounted() {
      this.canvas = this.el.querySelector('canvas')
      this.ctx = this.canvas.getContext('2d')
      this.terrainData = null
      this._terrainSnapshot = null
      this.entities = []
      this.center = { x: 0, z: 0 }
      this.zoom = 2        // CSS pixels per block
      this.offsetX = 0     // pan offset in CSS pixels
      this.offsetZ = 0
      this.dragging = false
      this.lastMouse = null
      this.dpr = window.devicePixelRatio || 1

      this._resizeHandler = () => this.resizeCanvas()
      this.resizeCanvas()
      window.addEventListener('resize', this._resizeHandler)

      // Receive terrain data from LiveView
      this.handleEvent("terrain_data", (data) => {
        this.terrainData = data.blocks
        this.center = data.center || { x: 0, z: 0 }
        // Reset view to center on scan
        this.offsetX = 0
        this.offsetZ = 0
        // Hide placeholder
        const ph = this.el.querySelector('#world-map-placeholder')
        if (ph) ph.style.display = 'none'
        this.render()
      })

      // Receive entity positions (bots + players) — only re-render overlay
      this.handleEvent("entity_positions", (data) => {
        this.entities = data.entities || []
        this.renderOverlay()
      })

      this.setupInteraction()
      this.render()
    },

    resizeCanvas() {
      const rect = this.el.getBoundingClientRect()
      this.dpr = window.devicePixelRatio || 1
      // Set canvas buffer to native resolution, CSS stays at layout size
      this.canvas.width = Math.floor(rect.width * this.dpr)
      this.canvas.height = Math.floor(rect.height * this.dpr)
      this.canvas.style.width = rect.width + 'px'
      this.canvas.style.height = rect.height + 'px'
      this.cssW = rect.width
      this.cssH = rect.height
      this.render()
    },

    render() {
      if (!this.ctx) return
      const ctx = this.ctx
      const w = this.canvas.width   // native pixels
      const h = this.canvas.height

      // Clear
      ctx.fillStyle = '#050508'
      ctx.fillRect(0, 0, w, h)

      if (!this.terrainData || this.terrainData.length === 0) return

      this.renderTerrain(ctx, w, h)
      this.renderGrid(ctx, w, h)

      // Snapshot terrain+grid (before entities) for fast overlay redraws
      this._terrainSnapshot = ctx.getImageData(0, 0, w, h)

      this.renderEntities(ctx, w, h)
      this.renderHUD(ctx, w, h)
    },

    // Fast path: restore terrain snapshot and redraw only entities
    renderOverlay() {
      if (!this.ctx) return
      const w = this.canvas.width
      const h = this.canvas.height

      if (this._terrainSnapshot && this._terrainSnapshot.width === w) {
        this.ctx.putImageData(this._terrainSnapshot, 0, 0)
        this.renderEntities(this.ctx, w, h)
        this.renderHUD(this.ctx, w, h)
      } else {
        this.render()
      }
    },

    // Convert CSS-space zoom/offset to native pixel coordinates
    nativeZoom() { return this.zoom * this.dpr },
    nativeOffsetX() { return this.offsetX * this.dpr },
    nativeOffsetZ() { return this.offsetZ * this.dpr },

    renderTerrain(ctx, w, h) {
      const zoom = this.nativeZoom()
      const ox = this.nativeOffsetX()
      const oz = this.nativeOffsetZ()
      const cx = this.center.x
      const cz = this.center.z
      const halfW = w / 2
      const halfH = h / 2
      const data = this.terrainData

      // Find Y range for height shading
      let minY = 320, maxY = -64
      for (let i = 0; i < data.length; i++) {
        const y = data[i][2]
        if (y < minY) minY = y
        if (y > maxY) maxY = y
      }
      const yRange = Math.max(maxY - minY, 1)

      if (zoom >= 1) {
        // Use ImageData pixel buffer for speed
        const imgData = ctx.getImageData(0, 0, w, h)
        const pixels = imgData.data
        const blockSize = Math.ceil(zoom)

        for (let i = 0; i < data.length; i++) {
          const block = data[i]
          const sx = Math.floor(halfW + (block[0] - cx) * zoom + ox)
          const sz = Math.floor(halfH + (block[1] - cz) * zoom + oz)

          if (sx + blockSize < 0 || sx >= w || sz + blockSize < 0 || sz >= h) continue

          const rgb = BLOCK_COLORS[block[3]] || DEFAULT_COLOR
          const shade = 0.5 + ((block[2] - minY) / yRange) * 0.5
          const r = Math.min(255, (rgb[0] * shade) | 0)
          const g = Math.min(255, (rgb[1] * shade) | 0)
          const b = Math.min(255, (rgb[2] * shade) | 0)

          const x0 = Math.max(0, sx), x1 = Math.min(w, sx + blockSize)
          const z0 = Math.max(0, sz), z1 = Math.min(h, sz + blockSize)
          for (let pz = z0; pz < z1; pz++) {
            let off = (pz * w + x0) * 4
            for (let px = x0; px < x1; px++) {
              pixels[off] = r
              pixels[off + 1] = g
              pixels[off + 2] = b
              pixels[off + 3] = 255
              off += 4
            }
          }
        }
        ctx.putImageData(imgData, 0, 0)
      } else {
        // Sub-pixel zoom: fillRect (fewer visible blocks at this scale)
        for (let i = 0; i < data.length; i++) {
          const block = data[i]
          const screenX = halfW + (block[0] - cx) * zoom + ox
          const screenZ = halfH + (block[1] - cz) * zoom + oz
          if (screenX + 1 < 0 || screenX > w || screenZ + 1 < 0 || screenZ > h) continue

          const rgb = BLOCK_COLORS[block[3]] || DEFAULT_COLOR
          const shade = 0.5 + ((block[2] - minY) / yRange) * 0.5
          const r = Math.min(255, (rgb[0] * shade) | 0)
          const g = Math.min(255, (rgb[1] * shade) | 0)
          const b = Math.min(255, (rgb[2] * shade) | 0)
          ctx.fillStyle = `rgb(${r},${g},${b})`
          ctx.fillRect(screenX, screenZ, zoom, zoom)
        }
      }
    },

    renderGrid(ctx, w, h) {
      if (this.zoom < 1) return  // Too zoomed out for grid
      const zoom = this.nativeZoom()
      const ox = this.nativeOffsetX()
      const oz = this.nativeOffsetZ()
      const cx = this.center.x
      const cz = this.center.z
      const halfW = w / 2
      const halfH = h / 2

      ctx.strokeStyle = 'rgba(255, 255, 255, 0.05)'
      ctx.lineWidth = this.dpr

      // Chunk boundaries (every 16 blocks), accounting for pan offset
      const startBlockX = cx - (halfW + ox) / zoom
      const endBlockX = cx + (halfW - ox) / zoom
      const startBlockZ = cz - (halfH + oz) / zoom
      const endBlockZ = cz + (halfH - oz) / zoom

      const firstChunkX = Math.floor(startBlockX / 16) * 16
      const firstChunkZ = Math.floor(startBlockZ / 16) * 16

      for (let bx = firstChunkX; bx <= endBlockX; bx += 16) {
        const sx = halfW + (bx - cx) * zoom + ox
        ctx.beginPath()
        ctx.moveTo(sx, 0)
        ctx.lineTo(sx, h)
        ctx.stroke()
      }

      for (let bz = firstChunkZ; bz <= endBlockZ; bz += 16) {
        const sz = halfH + (bz - cz) * zoom + oz
        ctx.beginPath()
        ctx.moveTo(0, sz)
        ctx.lineTo(w, sz)
        ctx.stroke()
      }
    },

    renderEntities(ctx, w, h) {
      const zoom = this.nativeZoom()
      const ox = this.nativeOffsetX()
      const oz = this.nativeOffsetZ()
      const cx = this.center.x
      const cz = this.center.z
      const halfW = w / 2
      const halfH = h / 2
      const dpr = this.dpr
      const radius = Math.max(4 * dpr, zoom * 1.5)

      for (const ent of this.entities) {
        if (ent.x == null || ent.z == null) continue
        const sx = halfW + (ent.x - cx) * zoom + ox
        const sz = halfH + (ent.z - cz) * zoom + oz

        // Dot
        ctx.beginPath()
        ctx.arc(sx, sz, radius, 0, Math.PI * 2)
        ctx.fillStyle = ent.color || '#ffffff'
        ctx.fill()

        // Glow
        ctx.beginPath()
        ctx.arc(sx, sz, radius + 2 * dpr, 0, Math.PI * 2)
        ctx.strokeStyle = ent.color || '#ffffff'
        ctx.lineWidth = dpr
        ctx.globalAlpha = 0.4
        ctx.stroke()
        ctx.globalAlpha = 1.0

        // Label
        ctx.font = `${10 * dpr}px monospace`
        ctx.fillStyle = ent.color || '#ffffff'
        ctx.textAlign = 'center'
        ctx.fillText(ent.name, sx, sz - radius - 4 * dpr)
      }
    },

    renderHUD(ctx, w, h) {
      const dpr = this.dpr
      const pad = 8 * dpr
      const fontSize = 10 * dpr
      const blockRadius = Math.round((this.cssW || w) / this.zoom / 2)

      ctx.font = `${fontSize}px monospace`
      ctx.textAlign = 'right'
      ctx.fillStyle = 'rgba(0, 255, 255, 0.5)'
      ctx.fillText(`${this.zoom.toFixed(1)}x  ~${blockRadius * 2} blocks`, w - pad, h - pad)
    },

    setupInteraction() {
      // Mouse wheel zoom (toward mouse position)
      this.canvas.addEventListener('wheel', (e) => {
        e.preventDefault()
        const oldZoom = this.zoom
        const factor = e.deltaY > 0 ? 0.85 : 1.18
        this.zoom = Math.max(0.25, Math.min(16, this.zoom * factor))
        const ratio = this.zoom / oldZoom

        // Zoom toward mouse: keep the world point under cursor fixed
        // All in CSS pixel space (offsets are CSS pixels)
        const rect = this.canvas.getBoundingClientRect()
        const mx = e.clientX - rect.left
        const mz = e.clientY - rect.top
        const halfW = (this.cssW || rect.width) / 2
        const halfH = (this.cssH || rect.height) / 2

        const dx = mx - halfW - this.offsetX
        const dz = mz - halfH - this.offsetZ
        this.offsetX -= dx * (ratio - 1)
        this.offsetZ -= dz * (ratio - 1)

        this.render()
      }, { passive: false })

      // Click-drag pan
      this.canvas.addEventListener('mousedown', (e) => {
        this.dragging = true
        this.lastMouse = { x: e.clientX, y: e.clientY }
        this.canvas.style.cursor = 'grabbing'
      })

      this._moveHandler = (e) => {
        if (!this.dragging || !this.lastMouse) return
        this.offsetX += e.clientX - this.lastMouse.x
        this.offsetZ += e.clientY - this.lastMouse.y
        this.lastMouse = { x: e.clientX, y: e.clientY }
        this.render()
      }
      window.addEventListener('mousemove', this._moveHandler)

      this._upHandler = () => {
        this.dragging = false
        this.lastMouse = null
        this.canvas.style.cursor = 'default'
      }
      window.addEventListener('mouseup', this._upHandler)
    },

    destroyed() {
      if (this._resizeHandler) window.removeEventListener('resize', this._resizeHandler)
      if (this._moveHandler) window.removeEventListener('mousemove', this._moveHandler)
      if (this._upHandler) window.removeEventListener('mouseup', this._upHandler)
    }
  }})(),
  ChatScroll: {
    mounted() {
      this.isAtBottom = true
      this.scrollToBottom()

      this.el.addEventListener("scroll", () => {
        const threshold = 50
        const atBottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < threshold
        if (atBottom !== this.isAtBottom) {
          this.isAtBottom = atBottom
          this.pushEventTo(this.el, "scroll_state_changed", { at_bottom: atBottom })
        }
      })

      this.observer = new MutationObserver(() => {
        if (this.isAtBottom) {
          this.scrollToBottom()
        }
      })
      this.observer.observe(this.el, { childList: true, subtree: true })
    },
    updated() {
      if (this.isAtBottom) {
        this.scrollToBottom()
      }
    },
    destroyed() {
      if (this.observer) this.observer.disconnect()
    },
    scrollToBottom() {
      this.el.scrollTop = this.el.scrollHeight
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

