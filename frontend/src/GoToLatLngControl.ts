import maplibregl from 'maplibre-gl'

// A custom MapLibre control that lets the user type a latitude/longitude and
// flies the map there. Implements the same IControl interface Mapbox uses:
//   - onAdd(map): build + return a DOM element; MapLibre slots it into the
//     control stack (so it lines up with the other buttons).
//   - onRemove(): tear everything down when the map is destroyed.
//
// It's fully self-contained (no event bus) — it only ever talks to the map
// instance it was added to.
export class GoToLatLngControl implements maplibregl.IControl {
  private map?: maplibregl.Map
  private container!: HTMLDivElement
  private panel!: HTMLDivElement
  private latInput!: HTMLInputElement
  private lngInput!: HTMLInputElement
  private marker?: maplibregl.Marker

  onAdd(map: maplibregl.Map): HTMLElement {
    this.map = map

    // The control group — same classes the built-in controls use, so it
    // picks up MapLibre's button styling automatically.
    this.container = document.createElement('div')
    this.container.className = 'maplibregl-ctrl maplibregl-ctrl-group'
    this.container.style.position = 'relative'

    // Toggle button (a crosshair/target glyph).
    const button = document.createElement('button')
    button.type = 'button'
    button.title = 'Go to latitude / longitude'
    button.setAttribute('aria-label', 'Go to latitude / longitude')
    button.innerHTML = targetIcon
    button.onclick = () => this.togglePanel()
    this.container.appendChild(button)

    // The little input panel — hidden until the button is clicked. Positioned
    // just to the right of the control group.
    this.panel = document.createElement('div')
    Object.assign(this.panel.style, {
      position: 'absolute',
      top: '0',
      left: '36px',
      display: 'none',
      background: '#fff',
      padding: '8px',
      borderRadius: '4px',
      boxShadow: '0 1px 4px rgba(0,0,0,0.3)',
      width: '150px',
    } as CSSStyleDeclaration)

    this.latInput = makeInput('Latitude', -90, 90)
    this.lngInput = makeInput('Longitude', -180, 180)

    const goButton = document.createElement('button')
    goButton.type = 'button'
    goButton.textContent = 'Go'
    Object.assign(goButton.style, {
      flex: '1',
      padding: '4px',
      cursor: 'pointer',
    } as CSSStyleDeclaration)
    goButton.onclick = () => this.goToLocation()

    // Clear button — removes the marker and empties the inputs.
    const clearButton = document.createElement('button')
    clearButton.type = 'button'
    clearButton.textContent = 'Clear'
    Object.assign(clearButton.style, {
      flex: '1',
      padding: '4px',
      cursor: 'pointer',
    } as CSSStyleDeclaration)
    clearButton.onclick = () => this.clearMarker()

    // Row to hold Go + Clear side by side.
    const buttonRow = document.createElement('div')
    Object.assign(buttonRow.style, { display: 'flex', gap: '6px' } as CSSStyleDeclaration)
    buttonRow.append(goButton, clearButton)

    // Enter in either field submits.
    const onEnter = (e: KeyboardEvent) => { if (e.key === 'Enter') this.goToLocation() }
    this.latInput.addEventListener('keydown', onEnter)
    this.lngInput.addEventListener('keydown', onEnter)

    this.panel.append(this.latInput, this.lngInput, buttonRow)
    this.container.appendChild(this.panel)

    return this.container
  }

  onRemove(): void {
    this.marker?.remove()
    this.container.parentNode?.removeChild(this.container)
    this.map = undefined
  }

  private togglePanel(): void {
    const showing = this.panel.style.display === 'block'
    this.panel.style.display = showing ? 'none' : 'block'
    if (!showing) this.latInput.focus()
  }

  private goToLocation(): void {
    if (!this.map) return
    const lat = parseFloat(this.latInput.value)
    const lng = parseFloat(this.lngInput.value)

    // Validate before flying anywhere.
    if (Number.isNaN(lat) || lat < -90 || lat > 90) { this.latInput.focus(); return }
    if (Number.isNaN(lng) || lng < -180 || lng > 180) { this.lngInput.focus(); return }

    this.map.flyTo({ center: [lng, lat], zoom: Math.max(this.map.getZoom(), 14) })

    // Drop (or move) a marker at the target so it's easy to see.
    if (this.marker) this.marker.setLngLat([lng, lat])
    else this.marker = new maplibregl.Marker({ color: '#e91e63' }).setLngLat([lng, lat]).addTo(this.map)

    this.panel.style.display = 'none'
  }

  private clearMarker(): void {
    this.marker?.remove()
    this.marker = undefined
    this.latInput.value = ''
    this.lngInput.value = ''
    this.latInput.focus()
  }
}

// A labelled number input for the panel.
function makeInput(placeholder: string, min: number, max: number): HTMLInputElement {
  const input = document.createElement('input')
  input.type = 'number'
  input.placeholder = placeholder
  input.min = String(min)
  input.max = String(max)
  input.step = 'any'
  Object.assign(input.style, {
    width: '100%',
    boxSizing: 'border-box',
    marginBottom: '6px',
    padding: '4px',
  } as CSSStyleDeclaration)
  return input
}

// Inline SVG crosshair icon (currentColor so it matches the other controls).
const targetIcon = `
<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor"
     stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:middle">
  <circle cx="12" cy="12" r="7"></circle>
  <line x1="12" y1="1" x2="12" y2="4"></line>
  <line x1="12" y1="20" x2="12" y2="23"></line>
  <line x1="1" y1="12" x2="4" y2="12"></line>
  <line x1="20" y1="12" x2="23" y2="12"></line>
</svg>`
