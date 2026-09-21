import { useEffect, useMemo, useRef, useState } from 'react'

const WS_URL = 'ws://127.0.0.1:8000/ws/tracks'
const VIDEO_URL = 'http://127.0.0.1:8000/video_feed'
const HIST_LIMIT = 24

function statusLabel(stats) {
  if ((stats?.danger_count ?? 0) > 0) return 'DANGER'
  if ((stats?.slow_count ?? 0) > 0) return 'SLOW'
  return 'NORMAL'
}

function statusColor(label) {
  if (label === 'DANGER') return '#ef4444'
  if (label === 'SLOW') return '#f59e0b'
  return '#22d3a0'
}

function formatSpeed(value) {
  return Number.isFinite(value) ? value.toFixed(2) : '0.00'
}

function speedToBar(speed) {
  return `${Math.max(0, Math.min(100, Math.round((speed / 1.2) * 100)))}%`
}

function makeEmptyStats() {
  return {
    count: 0,
    avg_speed: 0,
    min_speed: 0,
    danger_count: 0,
    slow_count: 0,
    normal_count: 0,
  }
}

function Card({ label, value, unit, accent }) {
  return (
    <div
      style={{
        flex: 1,
        minWidth: 140,
        background: 'rgba(7, 16, 26, 0.92)',
        border: '1px solid rgba(56, 189, 248, 0.14)',
        borderTop: `3px solid ${accent}`,
        borderRadius: 12,
        padding: '12px 14px',
      }}
    >
      <div style={{ fontSize: 10, letterSpacing: 1.5, color: '#6b8bab' }}>{label}</div>
      <div style={{ marginTop: 6, fontSize: 28, fontWeight: 800, color: accent, lineHeight: 1 }}>
        {value}
      </div>
      <div style={{ marginTop: 4, fontSize: 10, color: '#4f6d87' }}>{unit}</div>
    </div>
  )
}

export default function App() {
  const [wsStatus, setWsStatus] = useState('CONNECTING')
  const [tracks, setTracks] = useState([])
  const [stats, setStats] = useState(makeEmptyStats())
  const [frameDims, setFrameDims] = useState({ width: 640, height: 480 })
  const [frameCount, setFrameCount] = useState(0)
  const [fps, setFps] = useState(0)
  const [frameSrc, setFrameSrc] = useState('')
  const [history, setHistory] = useState([])

  const wsRef = useRef(null)
  const retryRef = useRef(null)

  useEffect(() => {
    const connect = () => {
      setWsStatus('CONNECTING')
      const ws = new WebSocket(WS_URL)
      wsRef.current = ws

      ws.onopen = () => {
        setWsStatus('LIVE')
        if (retryRef.current) {
          clearTimeout(retryRef.current)
          retryRef.current = null
        }
      }

      ws.onmessage = (event) => {
        let msg
        try {
          msg = JSON.parse(event.data)
        } catch {
          return
        }

        const nextTracks = Array.isArray(msg.tracks) ? msg.tracks : []
        const nextStats = msg.stats ?? makeEmptyStats()

        setTracks(nextTracks)
        setStats(nextStats)
        if (msg.frame_dims) setFrameDims(msg.frame_dims)
        if (Number.isFinite(msg.frame_count)) setFrameCount(msg.frame_count)
        if (Number.isFinite(msg.fps)) setFps(msg.fps)

        if (msg.frame_b64) {
          setFrameSrc(`data:image/jpeg;base64,${msg.frame_b64}`)
        }

        setHistory((prev) => {
          const tick = Number.isFinite(msg.frame_count) ? msg.frame_count : prev.length + 1
          const row = { tick }
          nextTracks.forEach((track) => {
            row[`E-${String(track.id).padStart(3, '0')}`] = track.speed ?? 0
          })
          return [...prev.slice(-(HIST_LIMIT - 1)), row]
        })
      }

      ws.onerror = () => setWsStatus('ERROR')
      ws.onclose = () => {
        setWsStatus('ERROR')
        retryRef.current = setTimeout(connect, 2000)
      }
    }

    connect()

    return () => {
      if (retryRef.current) clearTimeout(retryRef.current)
      if (wsRef.current) wsRef.current.close()
    }
  }, [])

  const overall = useMemo(() => statusLabel(stats), [stats])
  const overallColor = statusColor(overall)
  const overlayReady = Boolean(frameSrc)

  return (
    <main
      style={{
        minHeight: '100vh',
        padding: 16,
        boxSizing: 'border-box',
        color: '#d8ecff',
        background:
          'radial-gradient(circle at top left, rgba(56, 189, 248, 0.14), transparent 28%), radial-gradient(circle at bottom right, rgba(34, 211, 160, 0.11), transparent 30%), #02060c',
      }}
    >
      <div
        style={{
          maxWidth: 1440,
          margin: '0 auto',
          display: 'grid',
          gap: 14,
        }}
      >
        <header
          style={{
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'center',
            padding: '10px 14px',
            border: '1px solid rgba(56, 189, 248, 0.14)',
            borderRadius: 14,
            background: 'rgba(4, 10, 18, 0.8)',
            backdropFilter: 'blur(8px)',
          }}
        >
          <div>
            <div style={{ fontSize: 15, fontWeight: 800, letterSpacing: 2 }}>SMART INTERSECTION DASHBOARD</div>
            <div style={{ marginTop: 4, fontSize: 11, color: '#6b8bab' }}>
              YOLO bridge + SUMO live monitor
            </div>
          </div>

          <div style={{ textAlign: 'right' }}>
            <div
              style={{
                fontSize: 12,
                fontWeight: 800,
                color: wsStatus === 'LIVE' ? '#22d3a0' : '#ef4444',
                letterSpacing: 1,
              }}
            >
              {wsStatus}
            </div>
            <div style={{ marginTop: 4, fontSize: 11, color: '#6b8bab' }}>
              {overall} | FPS {formatSpeed(fps)}
            </div>
          </div>
        </header>

        <section
          style={{
            display: 'grid',
            gridTemplateColumns: 'minmax(0, 1.15fr) minmax(320px, 0.85fr)',
            gap: 14,
          }}
        >
          <div
            style={{
              position: 'relative',
              minHeight: 480,
              borderRadius: 16,
              overflow: 'hidden',
              border: '1px solid rgba(56, 189, 248, 0.14)',
              background: '#07101a',
            }}
          >
            {overlayReady ? (
              <img
                src={frameSrc}
                alt="YOLO video feed"
                style={{ display: 'block', width: '100%', height: '100%', objectFit: 'contain' }}
              />
            ) : (
              <div
                style={{
                  position: 'absolute',
                  inset: 0,
                  display: 'grid',
                  placeItems: 'center',
                  color: '#5b7690',
                  fontSize: 14,
                  textAlign: 'center',
                  padding: 24,
                }}
              >
                <div>
                  <div style={{ fontWeight: 700, color: '#8fb8d8' }}>Waiting for video feed</div>
                  <div style={{ marginTop: 8 }}>Backend is connected, but no frame has arrived yet.</div>
                  <div style={{ marginTop: 8, fontSize: 12, color: '#4f6d87' }}>{VIDEO_URL}</div>
                </div>
              </div>
            )}

            <div
              style={{
                position: 'absolute',
                top: 10,
                left: 10,
                padding: '6px 10px',
                borderRadius: 999,
                background: 'rgba(2, 6, 12, 0.7)',
                border: '1px solid rgba(56, 189, 248, 0.18)',
                fontSize: 11,
                color: '#9ed7ff',
              }}
            >
              FRAME {frameCount} | {frameDims.width}x{frameDims.height}
            </div>

            <div
              style={{
                position: 'absolute',
                top: 10,
                right: 10,
                padding: '6px 10px',
                borderRadius: 999,
                background: 'rgba(2, 6, 12, 0.7)',
                border: `1px solid ${overallColor}44`,
                fontSize: 11,
                color: overallColor,
                fontWeight: 700,
              }}
            >
              {overall}
            </div>
          </div>

          <div style={{ display: 'grid', gap: 12 }}>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, minmax(0, 1fr))', gap: 12 }}>
              <Card label="DETECTED" value={stats.count} unit="persons" accent="#22d3a0" />
              <Card label="AVG SPEED" value={formatSpeed(stats.avg_speed)} unit="m/s" accent="#38bdf8" />
              <Card label="MIN SPEED" value={formatSpeed(stats.min_speed)} unit="m/s" accent={overallColor} />
            </div>

            <div
              style={{
                padding: 14,
                borderRadius: 14,
                background: 'rgba(7, 16, 26, 0.92)',
                border: `1px solid ${overallColor}22`,
              }}
            >
              <div style={{ fontSize: 11, letterSpacing: 1.4, color: '#6b8bab' }}>PEDESTRIAN RISK</div>
              <div style={{ marginTop: 10, fontSize: 28, fontWeight: 800, color: overallColor }}>
                {overall}
              </div>
              <div style={{ marginTop: 8, fontSize: 12, color: '#9ed7ff' }}>
                Decision: extend green {overall === 'DANGER' ? '+15s' : overall === 'SLOW' ? '+8s' : '+0s'}
              </div>
              <div style={{ marginTop: 10, display: 'flex', gap: 10, flexWrap: 'wrap', fontSize: 11 }}>
                <span style={{ color: '#ef4444' }}>danger: {stats.danger_count}</span>
                <span style={{ color: '#f59e0b' }}>slow: {stats.slow_count}</span>
                <span style={{ color: '#22d3a0' }}>normal: {stats.normal_count}</span>
              </div>
            </div>

            <div
              style={{
                padding: 14,
                borderRadius: 14,
                background: 'rgba(7, 16, 26, 0.92)',
                border: '1px solid rgba(56, 189, 248, 0.14)',
              }}
            >
              <div style={{ fontSize: 11, letterSpacing: 1.4, color: '#6b8bab' }}>LIVE SPEED HISTORY</div>
              <div style={{ marginTop: 12, display: 'grid', gap: 8 }}>
                {history.length === 0 ? (
                  <div style={{ color: '#4f6d87', fontSize: 12 }}>No history yet.</div>
                ) : (
                  history.slice(-6).map((row) => (
                    <div key={row.tick} style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                      <div style={{ width: 54, color: '#6b8bab', fontSize: 11 }}>#{row.tick}</div>
                      <div style={{ flex: 1, height: 10, borderRadius: 999, background: '#07101a', overflow: 'hidden' }}>
                        <div
                          style={{
                            width: speedToBar(row['E-001'] ?? 0),
                            height: '100%',
                            background: 'linear-gradient(90deg, #22d3a0, #38bdf8)',
                          }}
                        />
                      </div>
                    </div>
                  ))
                )}
              </div>
            </div>
          </div>
        </section>

        <section
          style={{
            borderRadius: 16,
            overflow: 'hidden',
            border: '1px solid rgba(56, 189, 248, 0.14)',
            background: 'rgba(7, 16, 26, 0.92)',
          }}
        >
          <div style={{ padding: '10px 14px', borderBottom: '1px solid rgba(56, 189, 248, 0.12)', color: '#6b8bab', fontSize: 11 }}>
            TRACK TABLE
          </div>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
            <thead>
              <tr style={{ textAlign: 'left', color: '#6b8bab' }}>
                <th style={{ padding: '10px 14px' }}>TRACK</th>
                <th style={{ padding: '10px 14px' }}>SPEED</th>
                <th style={{ padding: '10px 14px' }}>BBOX</th>
                <th style={{ padding: '10px 14px' }}>STATUS</th>
                <th style={{ padding: '10px 14px' }}>CONFIRMED</th>
              </tr>
            </thead>
            <tbody>
              {tracks.length === 0 ? (
                <tr>
                  <td colSpan="5" style={{ padding: '18px 14px', color: '#4f6d87' }}>
                    {wsStatus === 'LIVE' ? 'No persons detected in frame yet.' : 'Waiting for backend connection...'}
                  </td>
                </tr>
              ) : (
                tracks.map((track) => {
                  const label = String(track.status ?? 'unknown').toUpperCase()
                  const accent = statusColor(label)
                  const [x = 0, y = 0, w = 0, h = 0] = Array.isArray(track.bbox) ? track.bbox : []

                  return (
                    <tr key={track.id} style={{ borderTop: '1px solid rgba(56, 189, 248, 0.08)' }}>
                      <td style={{ padding: '10px 14px', color: '#d8ecff', fontWeight: 700 }}>E-{String(track.id).padStart(3, '0')}</td>
                      <td style={{ padding: '10px 14px', color: accent, fontWeight: 700 }}>{formatSpeed(track.speed)} m/s</td>
                      <td style={{ padding: '10px 14px', color: '#6b8bab' }}>
                        {Math.round(x)},{Math.round(y)} {Math.round(w)}x{Math.round(h)}
                      </td>
                      <td style={{ padding: '10px 14px', color: accent, fontWeight: 700 }}>{label}</td>
                      <td style={{ padding: '10px 14px', color: track.confirmed === false ? '#f59e0b' : '#22d3a0' }}>
                        {track.confirmed === false ? 'ghost' : 'yes'}
                      </td>
                    </tr>
                  )
                })
              )}
            </tbody>
          </table>
        </section>
      </div>
    </main>
  )
}
