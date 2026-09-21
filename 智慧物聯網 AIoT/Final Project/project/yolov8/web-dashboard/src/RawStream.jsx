const STREAM_URL = 'http://127.0.0.1:8000/video_feed'

export default function RawStream() {
  return (
    <main
      style={{
        position: 'fixed',
        inset: 0,
        margin: 0,
        background: '#02060c',
        color: '#d8ecff',
        overflow: 'hidden',
        fontFamily: 'monospace',
      }}
    >
      <div
        style={{
          position: 'absolute',
          top: 12,
          left: 12,
          zIndex: 2,
          padding: '8px 12px',
          border: '1px solid rgba(56, 189, 248, 0.35)',
          borderRadius: 8,
          background: 'rgba(2, 6, 12, 0.65)',
          backdropFilter: 'blur(8px)',
        }}
      >
        <div style={{ fontSize: 12, fontWeight: 700, letterSpacing: 1 }}>
          YOLO RAW VIDEO STREAM
        </div>
        <div style={{ fontSize: 10, color: '#7aa7c7', marginTop: 2 }}>
          {STREAM_URL}
        </div>
      </div>

      <img
        src={STREAM_URL}
        alt="YOLO raw stream"
        style={{
          width: '100vw',
          height: '100vh',
          objectFit: 'contain',
          display: 'block',
          background: '#000',
        }}
      />
    </main>
  )
}
