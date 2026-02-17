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
  WorldMap: {
    mounted() {
      this.canvas = this.el.querySelector('canvas')
      this.ctx = this.canvas.getContext('2d')
      this.terrainData = null
      this._terrainSnapshot = null
      this.entities = []
      this.center = { x: 0, z: 0 }
      this.zoom = 2        // pixels per block
      this.offsetX = 0     // pan offset in pixels
      this.offsetZ = 0
      this.dragging = false
      this.lastMouse = null

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
      this.canvas.width = rect.width
      this.canvas.height = rect.height
      this.render()
    },

    render() {
      if (!this.ctx) return
      const ctx = this.ctx
      const w = this.canvas.width
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
    },

    // Fast path: restore terrain snapshot and redraw only entities
    renderOverlay() {
      if (!this.ctx) return
      const w = this.canvas.width
      const h = this.canvas.height

      if (this._terrainSnapshot && this._terrainSnapshot.width === w) {
        // Restore terrain+grid snapshot, then draw fresh entities
        this.ctx.putImageData(this._terrainSnapshot, 0, 0)
        this.renderEntities(this.ctx, w, h)
      } else {
        // No snapshot yet, full render
        this.render()
      }
    },

    renderTerrain(ctx, w, h) {
      const zoom = this.zoom
      const cx = this.center.x
      const cz = this.center.z
      const halfW = w / 2
      const halfH = h / 2

      // Find Y range for height shading
      let minY = 320, maxY = -64
      for (const block of this.terrainData) {
        const y = block[2]
        if (y < minY) minY = y
        if (y > maxY) maxY = y
      }
      const yRange = Math.max(maxY - minY, 1)

      for (const block of this.terrainData) {
        const bx = block[0]
        const bz = block[1]
        const by = block[2]
        const name = block[3]

        const screenX = halfW + (bx - cx) * zoom + this.offsetX
        const screenZ = halfH + (bz - cz) * zoom + this.offsetZ

        // Frustum cull
        if (screenX + zoom < 0 || screenX > w || screenZ + zoom < 0 || screenZ > h) continue

        // Base color from block type
        const baseColor = this.blockColor(name)

        // Height shading: lighten high, darken low
        const heightFactor = (by - minY) / yRange  // 0 to 1
        const shade = 0.5 + heightFactor * 0.5      // 0.5 to 1.0

        ctx.fillStyle = this.shadeColor(baseColor, shade)
        ctx.fillRect(Math.floor(screenX), Math.floor(screenZ), Math.ceil(zoom), Math.ceil(zoom))
      }
    },

    renderGrid(ctx, w, h) {
      if (this.zoom < 1) return  // Too zoomed out for grid
      const zoom = this.zoom
      const cx = this.center.x
      const cz = this.center.z
      const halfW = w / 2
      const halfH = h / 2

      ctx.strokeStyle = 'rgba(255, 255, 255, 0.05)'
      ctx.lineWidth = 1

      // Chunk boundaries (every 16 blocks)
      const startBlockX = cx - halfW / zoom
      const endBlockX = cx + halfW / zoom
      const startBlockZ = cz - halfH / zoom
      const endBlockZ = cz + halfH / zoom

      const firstChunkX = Math.floor(startBlockX / 16) * 16
      const firstChunkZ = Math.floor(startBlockZ / 16) * 16

      for (let bx = firstChunkX; bx <= endBlockX; bx += 16) {
        const sx = halfW + (bx - cx) * zoom + this.offsetX
        ctx.beginPath()
        ctx.moveTo(sx, 0)
        ctx.lineTo(sx, h)
        ctx.stroke()
      }

      for (let bz = firstChunkZ; bz <= endBlockZ; bz += 16) {
        const sz = halfH + (bz - cz) * zoom + this.offsetZ
        ctx.beginPath()
        ctx.moveTo(0, sz)
        ctx.lineTo(w, sz)
        ctx.stroke()
      }
    },

    renderEntities(ctx, w, h) {
      const zoom = this.zoom
      const cx = this.center.x
      const cz = this.center.z
      const halfW = w / 2
      const halfH = h / 2
      const radius = Math.max(4, zoom * 1.5)

      for (const ent of this.entities) {
        if (ent.x == null || ent.z == null) continue
        const sx = halfW + (ent.x - cx) * zoom + this.offsetX
        const sz = halfH + (ent.z - cz) * zoom + this.offsetZ

        // Dot
        ctx.beginPath()
        ctx.arc(sx, sz, radius, 0, Math.PI * 2)
        ctx.fillStyle = ent.color || '#ffffff'
        ctx.fill()

        // Glow
        ctx.beginPath()
        ctx.arc(sx, sz, radius + 2, 0, Math.PI * 2)
        ctx.strokeStyle = ent.color || '#ffffff'
        ctx.lineWidth = 1
        ctx.globalAlpha = 0.4
        ctx.stroke()
        ctx.globalAlpha = 1.0

        // Label
        ctx.font = '10px monospace'
        ctx.fillStyle = ent.color || '#ffffff'
        ctx.textAlign = 'center'
        ctx.fillText(ent.name, sx, sz - radius - 4)
      }
    },

    setupInteraction() {
      // Mouse wheel zoom (toward mouse position)
      this.canvas.addEventListener('wheel', (e) => {
        e.preventDefault()
        const oldZoom = this.zoom
        const factor = e.deltaY > 0 ? 0.85 : 1.18
        this.zoom = Math.max(0.5, Math.min(8, this.zoom * factor))
        const ratio = this.zoom / oldZoom

        // Zoom toward mouse: keep the world point under cursor fixed
        const rect = this.canvas.getBoundingClientRect()
        const mx = e.clientX - rect.left
        const mz = e.clientY - rect.top
        const halfW = this.canvas.width / 2
        const halfH = this.canvas.height / 2

        // Point on canvas relative to center (before zoom)
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

      window.addEventListener('mousemove', (e) => {
        if (!this.dragging || !this.lastMouse) return
        this.offsetX += e.clientX - this.lastMouse.x
        this.offsetZ += e.clientY - this.lastMouse.y
        this.lastMouse = { x: e.clientX, y: e.clientY }
        this.render()
      })

      window.addEventListener('mouseup', () => {
        this.dragging = false
        this.lastMouse = null
        this.canvas.style.cursor = 'default'
      })
    },

    blockColor(name) {
      const colors = {
        grass_block: [86, 140, 60],
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
        oak_leaves: [58, 95, 22],
        spruce_leaves: [42, 75, 42],
        birch_leaves: [68, 105, 38],
        oak_planks: [162, 131, 78],
        snow: [240, 240, 255],
        snow_block: [240, 240, 255],
        ice: [145, 190, 230],
        packed_ice: [130, 170, 215],
        blue_ice: [100, 150, 230],
        clay: [160, 166, 179],
        terracotta: [152, 94, 67],
        sandstone: [216, 203, 155],
        red_sand: [190, 100, 50],
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
        path: [148, 130, 82],
        dirt_path: [148, 130, 82],
        moss_block: [80, 120, 50],
        mud: [60, 55, 50],
      }
      return colors[name] || [100, 100, 100]  // fallback gray
    },

    shadeColor(rgb, factor) {
      const r = Math.min(255, Math.round(rgb[0] * factor))
      const g = Math.min(255, Math.round(rgb[1] * factor))
      const b = Math.min(255, Math.round(rgb[2] * factor))
      return `rgb(${r},${g},${b})`
    },

    destroyed() {
      if (this._resizeHandler) window.removeEventListener('resize', this._resizeHandler)
    }
  },
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

