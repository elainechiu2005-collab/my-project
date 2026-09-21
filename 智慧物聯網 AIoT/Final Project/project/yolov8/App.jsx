import { useState, useEffect, useRef, useCallback } from "react";
import {
  LineChart, Line, XAxis, YAxis, CartesianGrid,
  Tooltip, ReferenceLine, ResponsiveContainer
} from "recharts";

// ─── Config ───────────────────────────────────────────────────────
const WS_URL    = "ws://localhost:8000/ws/tracks";
const THR_N     = 0.80;
const THR_S     = 0.45;
const HIST      = 30;          // chart history length
const RECONNECT = 2000;        // ms before reconnect attempt
const ECOLS     = [
  "#38bdf8","#c084fc","#fb923c","#f472b6",
  "#34d399","#a3e635","#fb7185","#fcd34d",
];

// ─── Helpers ──────────────────────────────────────────────────────
const statusOf  = s  => s >= THR_N ? "NORMAL" : s >= THR_S ? "SLOW" : "DANGER";
const colorOf   = s  => ({ NORMAL:"#22d3a0", SLOW:"#f59e0b", DANGER:"#ef4444" })[statusOf(s)];
const trackName = id => `E-${String(id).padStart(3, "0")}`;

// ─── Canvas drawing function ──────────────────────────────────────
/**
 * Draws bounding boxes, trajectory trails, ID labels, and speed text
 * onto a canvas element positioned over the video image.
 *
 * scaleX/scaleY convert from original video coordinates (from backend)
 * to the canvas's actual display size.
 */
function drawOverlay(canvas, tracks, dims) {
  if (!canvas) return;
  const dW = canvas.clientWidth;
  const dH = canvas.clientHeight;
  if (dW === 0 || dH === 0) return;

  canvas.width  = dW;
  canvas.height = dH;

  const sX = dW / (dims.width  || 640);
  const sY = dH / (dims.height || 480);
  const ctx = canvas.getContext("2d");
  ctx.clearRect(0, 0, dW, dH);

  tracks.forEach(track => {
    const [bx, by, bw, bh] = track.bbox;
    const x  = bx * sX,  y  = by  * sY;
    const w  = bw * sX,  h  = bh  * sY;
    const cx = (bx + bw / 2) * sX;
    const cy = (by + bh / 2) * sY;

    const color   = colorOf(track.speed);
    const isGhost = !track.confirmed;
    const isDanger = track.status === "danger";

    // ── Trajectory trail ────────────────────────────────────────
    const traj = track.trajectory || [];
    if (traj.length > 2) {
      ctx.save();
      ctx.globalAlpha = isGhost ? 0.25 : 0.55;
      ctx.strokeStyle = color;
      ctx.lineWidth   = 1.5;
      ctx.setLineDash([]);
      ctx.beginPath();
      traj.forEach(([tx, ty], i) => {
        const px = tx * sX, py = ty * sY;
        if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
      });
      ctx.stroke();
      ctx.restore();
    }

    // ── Bounding box ─────────────────────────────────────────────
    ctx.save();
    ctx.globalAlpha = isGhost ? 0.45 : 1.0;
    ctx.strokeStyle = color;
    ctx.lineWidth   = isDanger ? 2.5 : 2;
    if (isDanger) {
      ctx.setLineDash([6, 4]);
    } else {
      ctx.setLineDash([]);
    }

    // Box fill (subtle)
    ctx.fillStyle = color;
    ctx.globalAlpha = isGhost ? 0.04 : 0.09;
    ctx.fillRect(x, y, w, h);

    // Box stroke
    ctx.globalAlpha = isGhost ? 0.45 : 1.0;
    ctx.strokeRect(x, y, w, h);

    // Corner L-marks
    const L = Math.min(w, h) * 0.18;
    ctx.lineWidth   = 2.5;
    ctx.setLineDash([]);
    [[x,y,1,1],[x+w,y,-1,1],[x,y+h,1,-1],[x+w,y+h,-1,-1]].forEach(([px,py,sx,sy]) => {
      ctx.beginPath();
      ctx.moveTo(px, py); ctx.lineTo(px + sx*L, py);   ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(px, py); ctx.lineTo(px, py + sy*L);   ctx.stroke();
    });
    ctx.restore();

    // ── ID tag (filled rect + text) ───────────────────────────────
    const tagH  = 18, tagY = y - tagH;
    const label = `${trackName(track.id)}  ${track.speed.toFixed(2)} m/s`;
    ctx.save();
    ctx.globalAlpha = isGhost ? 0.55 : 1.0;
    ctx.fillStyle   = color;
    ctx.fillRect(x, tagY, w, tagH);
    ctx.fillStyle = "#000";
    ctx.font      = `bold ${Math.max(9, Math.round(sX * 10))}px monospace`;
    ctx.textBaseline = "middle";
    ctx.fillText(label, x + 4, tagY + tagH / 2);
    ctx.restore();

    // ── Status badge (SLOW / DANGER) ─────────────────────────────
    if (track.status !== "normal") {
      const badge = track.status === "danger" ? "⚠ DANGER" : "◆ SLOW";
      ctx.save();
      ctx.globalAlpha = isGhost ? 0.5 : 0.9;
      ctx.fillStyle   = color;
      ctx.font        = `bold ${Math.max(8, Math.round(sX * 9))}px monospace`;
      ctx.textBaseline = "top";
      ctx.fillText(badge, x + 2, y + h + 3);
      ctx.restore();
    }
  });
}

// ─── Speed chart tooltip ──────────────────────────────────────────
function ChartTip({ active, payload, label }) {
  if (!active || !payload?.length) return null;
  return (
    <div style={{ background:"#0c1825", border:"1px solid #1e3050",
      borderRadius:4, padding:"5px 9px", fontSize:10, fontFamily:"monospace" }}>
      <div style={{ color:"#4a6080", marginBottom:2 }}>Tick {label}</div>
      {payload.map(p => (
        <div key={p.name} style={{ color: p.color }}>
          {p.name}: {Number(p.value).toFixed(2)} m/s
        </div>
      ))}
    </div>
  );
}

// ─── Main dashboard ───────────────────────────────────────────────
export default function Dashboard() {
  // WS state
  const [wsStatus, setWsStatus] = useState("CONNECTING"); // CONNECTING | LIVE | ERROR
  const wsRef     = useRef(null);
  const reconnRef = useRef(null);

  // Tracking data
  const [tracks,      setTracks     ] = useState([]);
  const [stats,       setStats      ] = useState({ count:0, avg_speed:0, min_speed:0,
                                                   danger_count:0, slow_count:0, normal_count:0 });
  const [frameDims,   setFrameDims  ] = useState({ width:640, height:480 });
  const [frameCount,  setFrameCount ] = useState(0);
  const [serverFps,   setServerFps  ] = useState(0);

  // Video
  const [frameSrc,    setFrameSrc   ] = useState("");   // base64 JPEG data URL
  const imgRef        = useRef(null);
  const canvasRef     = useRef(null);

  // Chart
  const [chartData,   setChartData  ] = useState([]);
  // Track which IDs we know about (for chart lines)
  const knownIds      = useRef(new Set());

  // ── Draw overlay whenever tracks or frame changes ──────────────
  const lastTracksRef = useRef([]);
  const lastDimsRef   = useRef({ width:640, height:480 });

  useEffect(() => {
    lastTracksRef.current = tracks;
    lastDimsRef.current   = frameDims;
  }, [tracks, frameDims]);

  const redrawCanvas = useCallback(() => {
    drawOverlay(canvasRef.current, lastTracksRef.current, lastDimsRef.current);
  }, []);

  // Redraw whenever a new frame arrives
  useEffect(() => {
    drawOverlay(canvasRef.current, tracks, frameDims);
  }, [frameSrc, tracks, frameDims]);

  // Also redraw on window resize
  useEffect(() => {
    window.addEventListener("resize", redrawCanvas);
    return () => window.removeEventListener("resize", redrawCanvas);
  }, [redrawCanvas]);

  // ── WebSocket connection + reconnect ───────────────────────────
  const connect = useCallback(() => {
    if (wsRef.current?.readyState === WebSocket.OPEN) return;
    setWsStatus("CONNECTING");

    const ws = new WebSocket(WS_URL);
    wsRef.current = ws;

    ws.onopen = () => {
      setWsStatus("LIVE");
      clearTimeout(reconnRef.current);
    };

    ws.onmessage = (evt) => {
      let msg;
      try { msg = JSON.parse(evt.data); } catch { return; }

      const { tracks: t, stats: s, frame_b64, frame_dims,
              frame_count, fps } = msg;

      // Update tracks & stats
      setTracks(t || []);
      if (s) setStats(s);
      if (frame_dims) setFrameDims(frame_dims);
      if (frame_count) setFrameCount(frame_count);
      if (fps) setServerFps(fps);

      // Update video frame
      if (frame_b64) {
        setFrameSrc(`data:image/jpeg;base64,${frame_b64}`);
      }

      // Update chart
      if (t && t.length > 0) {
        const confirmed = t.filter(tr => tr.confirmed !== false);
        confirmed.forEach(tr => knownIds.current.add(tr.id));

        setChartData(prev => {
          const pt = { tick: frame_count || prev.length };
          confirmed.forEach(tr => { pt[trackName(tr.id)] = tr.speed; });
          return [...prev.slice(-(HIST - 1)), pt];
        });
      }
    };

    ws.onerror = () => setWsStatus("ERROR");
    ws.onclose = () => {
      setWsStatus("ERROR");
      reconnRef.current = setTimeout(connect, RECONNECT);
    };
  }, []);

  useEffect(() => {
    connect();
    return () => {
      clearTimeout(reconnRef.current);
      wsRef.current?.close();
    };
  }, [connect]);

  // ── Derived UI state ───────────────────────────────────────────
  const overallSt = stats.danger_count > 0 ? "DANGER"
                  : stats.slow_count   > 0 ? "SLOW"  : "NORMAL";
  const overallC  = colorOf(stats.min_speed || 1);
  const extraG    = stats.danger_count > 0 ? "+15s"
                  : stats.slow_count   > 0 ? "+8s" : "+0s (nominal)";

  const chartIds  = [...knownIds.current].slice(0, ECOLS.length);

  // ── Stat card ──────────────────────────────────────────────────
  const Card = ({ label, val, unit, col }) => (
    <div style={{ flex:1, background:"#080e18", border:"1px solid #0f1e2e",
      borderTop:`3px solid ${col}`, borderRadius:6, padding:"9px 11px" }}>
      <div style={{ color:"#2a4060", fontSize:9, fontFamily:"monospace",
        letterSpacing:1, marginBottom:3 }}>{label}</div>
      <div style={{ color:col, fontSize:21, fontFamily:"monospace",
        fontWeight:700, lineHeight:1 }}>{val}</div>
      <div style={{ color:"#2a4060", fontSize:9, fontFamily:"monospace",
        marginTop:2 }}>{unit}</div>
    </div>
  );

  return (
    <div style={{ background:"#050910", color:"#c0d8f0", padding:14,
      boxSizing:"border-box", minHeight:"100vh", fontFamily:"sans-serif" }}>
      <style>{`
        @keyframes _glow  { 0%,100%{opacity:1} 50%{opacity:.4} }
        @keyframes _blink { 0%,100%{opacity:1} 50%{opacity:.5} }
        @keyframes _pulse { 0%,100%{opacity:1} 50%{opacity:.2} }
      `}</style>

      {/* ═══ HEADER ══════════════════════════════════════════════ */}
      <div style={{ display:"flex", justifyContent:"space-between",
        alignItems:"center", borderBottom:"1px solid #0f1e2e",
        paddingBottom:10, marginBottom:12 }}>
        <div style={{ display:"flex", alignItems:"center", gap:10 }}>
          <div style={{ background:"linear-gradient(135deg,#22d3a0,#38bdf8)",
            borderRadius:4, padding:"3px 9px", fontSize:10,
            fontWeight:700, color:"#000", fontFamily:"monospace" }}>AI</div>
          <div>
            <div style={{ fontSize:15, fontWeight:700, color:"#ddf0ff",
              letterSpacing:2, fontFamily:"monospace" }}>
              SMART INTERSECTION — AI TRACKING DASHBOARD
            </div>
            <div style={{ fontSize:9, color:"#2a4060", fontFamily:"monospace",
              letterSpacing:1, marginTop:1 }}>
              smaRRRt · AIoT Final Project · YOLOv8s + DeepSORT ·
              FRAME {String(frameCount).padStart(6,"0")} · {serverFps} FPS
            </div>
          </div>
        </div>

        {/* WS status + overall risk */}
        <div style={{ textAlign:"right" }}>
          <div style={{ display:"flex", alignItems:"center", gap:8,
            justifyContent:"flex-end", marginBottom:4 }}>
            <span style={{ fontSize:8, fontFamily:"monospace", letterSpacing:1,
              color: wsStatus === "LIVE" ? "#22d3a0" : "#ef4444",
              animation: wsStatus === "CONNECTING" ? "_pulse 1s infinite" : "none" }}>
              ● {wsStatus}
            </span>
          </div>
          <div style={{ color: overallC, fontSize:14, fontFamily:"monospace",
            fontWeight:700, letterSpacing:3,
            animation: overallSt !== "NORMAL" ? "_glow 0.9s ease-in-out infinite" : "none" }}>
            ● {overallSt}
          </div>
          <div style={{ color:"#2a4060", fontSize:8, fontFamily:"monospace" }}>
            SYSTEM STATUS
          </div>
        </div>
      </div>

      {/* ═══ MAIN GRID ════════════════════════════════════════════ */}
      <div style={{ display:"grid",
        gridTemplateColumns:"minmax(0,57%) minmax(0,43%)", gap:12 }}>

        {/* ── LEFT: Video + Canvas Overlay ─────────────────────── */}
        <div>
          <div style={{ fontSize:8, color:"#2a4060", fontFamily:"monospace",
            letterSpacing:2, marginBottom:5 }}>
            ▶ VIDEO FEED — CAM-001 · YOLOv8s + DeepSORT TRACKING
          </div>

          {/* Video container: img + canvas stacked */}
          <div style={{ position:"relative", borderRadius:7, overflow:"hidden",
            border:"1px solid #1e3050", background:"#07101a" }}>
            {frameSrc ? (
              <img ref={imgRef} src={frameSrc} alt="video feed"
                style={{ display:"block", width:"100%", height:"auto" }}
                onLoad={redrawCanvas}
              />
            ) : (
              <div style={{ width:"100%", paddingTop:"56.25%", background:"#07101a",
                position:"relative" }}>
                <div style={{ position:"absolute", inset:0, display:"flex",
                  alignItems:"center", justifyContent:"center",
                  color:"#2a4060", fontFamily:"monospace", fontSize:12 }}>
                  {wsStatus === "CONNECTING"
                    ? "⌛ Connecting to backend…"
                    : "❌ No video signal — is the backend running?"}
                </div>
              </div>
            )}

            {/* Canvas overlay for bounding boxes & trails */}
            <canvas ref={canvasRef}
              style={{
                position:"absolute", top:0, left:0,
                width:"100%", height:"100%",
                pointerEvents:"none",
              }}
            />

            {/* Corner brackets */}
            {[{t:4,l:4},{t:4,r:4},{b:4,l:4},{b:4,r:4}].map((s,i) => (
              <div key={i} style={{
                position:"absolute", ...s, width:18, height:18,
                borderTop:    s.t != null ? "2px solid #22d3a0" : "none",
                borderBottom: s.b != null ? "2px solid #22d3a0" : "none",
                borderLeft:   s.l != null ? "2px solid #22d3a0" : "none",
                borderRight:  s.r != null ? "2px solid #22d3a0" : "none",
              }}/>
            ))}

            {/* LIVE badge */}
            <div style={{ position:"absolute", top:8, right:8,
              background:"rgba(239,68,68,.22)", border:"1px solid #ef4444",
              borderRadius:3, padding:"2px 7px", fontSize:9,
              color:"#ef4444", fontFamily:"monospace", fontWeight:700,
              display:"flex", alignItems:"center", gap:4 }}>
              <span style={{ display:"inline-block", width:6, height:6,
                background:"#ef4444", borderRadius:"50%",
                animation:"_pulse 0.9s ease-in-out infinite" }}/>
              LIVE · YOLOv8
            </div>

            {/* HUD bottom bar */}
            <div style={{ position:"absolute", bottom:5, left:6,
              fontSize:9, fontFamily:"monospace",
              color:"rgba(34,211,160,0.45)" }}>
              {`FRAME:${String(frameCount).padStart(5,"0")}  DeepSORT tracks: ${stats.count}`}
            </div>
          </div>
        </div>

        {/* ── RIGHT: Data panel ─────────────────────────────────── */}
        <div style={{ display:"flex", flexDirection:"column", gap:10 }}>

          {/* Stat cards */}
          <div style={{ display:"flex", gap:8 }}>
            <Card label="DETECTED"    val={stats.count}              unit="persons"  col="#22d3a0"/>
            <Card label="AVG SPEED"   val={stats.avg_speed?.toFixed(2) ?? "—"} unit="m/s" col="#38bdf8"/>
            <Card label="MIN SPEED ⚠" val={stats.min_speed?.toFixed(2) ?? "—"} unit="m/s" col={overallC}/>
          </div>

          {/* Risk assessment */}
          <div style={{ background:"#080e18", borderLeft:`3px solid ${overallC}`,
            border:`1px solid ${overallC}28`, borderRadius:6, padding:"10px 12px" }}>
            <div style={{ fontSize:8, color:"#2a4060", fontFamily:"monospace",
              letterSpacing:2, marginBottom:6 }}>PEDESTRIAN RISK ASSESSMENT</div>
            <div style={{ display:"flex", justifyContent:"space-between",
              alignItems:"flex-start" }}>
              <div>
                <div style={{ color:overallC, fontSize:19, fontFamily:"monospace",
                  fontWeight:700, letterSpacing:4,
                  animation: overallSt !== "NORMAL" ? "_glow 1.2s ease-in-out infinite" : "none" }}>
                  {overallSt}
                </div>
                <div style={{ marginTop:7, padding:"4px 8px", background:"#040810",
                  borderRadius:4, fontSize:9, fontFamily:"monospace",
                  color:"#1e5040", borderLeft:"2px solid #22d3a0" }}>
                  Decision: extend green{" "}
                  <span style={{ color:"#f59e0b", fontWeight:700 }}>{extraG}</span>
                </div>
              </div>
              <div style={{ fontSize:11, fontFamily:"monospace",
                lineHeight:2, textAlign:"right" }}>
                <div style={{ color:"#ef4444" }}>⚠ {stats.danger_count} DANGER</div>
                <div style={{ color:"#f59e0b" }}>◆ {stats.slow_count} SLOW</div>
                <div style={{ color:"#22d3a0" }}>✓ {stats.normal_count} NORMAL</div>
              </div>
            </div>
          </div>

          {/* Speed chart */}
          <div style={{ background:"#080e18", border:"1px solid #0f1e2e",
            borderRadius:6, padding:"8px 10px 4px", flex:1 }}>
            <div style={{ fontSize:8, color:"#2a4060", fontFamily:"monospace",
              letterSpacing:2, marginBottom:4 }}>
              ▶ REAL-TIME SPEED HISTORY (m/s)
            </div>
            <div style={{ display:"flex", gap:8, flexWrap:"wrap", marginBottom:3 }}>
              {chartIds.map((id, i) => (
                <span key={id} style={{ fontSize:8, fontFamily:"monospace",
                  color: ECOLS[i % ECOLS.length] }}>
                  ─ {trackName(id)}
                </span>
              ))}
            </div>
            <ResponsiveContainer width="100%" height={155}>
              <LineChart data={chartData} margin={{ top:4, right:28, left:-14, bottom:0 }}>
                <CartesianGrid strokeDasharray="2 4" stroke="rgba(255,255,255,0.04)"/>
                <XAxis dataKey="tick" tick={{ fill:"#2a4060", fontSize:8, fontFamily:"monospace" }} interval={4}/>
                <YAxis domain={[0,1.2]} tick={{ fill:"#2a4060", fontSize:8, fontFamily:"monospace" }} tickCount={5}/>
                <Tooltip content={<ChartTip/>}/>
                <ReferenceLine y={THR_N} stroke="rgba(34,211,160,0.22)" strokeDasharray="3 3"/>
                <ReferenceLine y={THR_S} stroke="rgba(239,68,68,0.22)"  strokeDasharray="3 3"/>
                {chartIds.map((id, i) => (
                  <Line key={id} type="monotone" dataKey={trackName(id)}
                    stroke={ECOLS[i % ECOLS.length]} strokeWidth={1.5}
                    dot={false} isAnimationActive={false}/>
                ))}
              </LineChart>
            </ResponsiveContainer>
            <div style={{ display:"flex", gap:12, marginTop:2 }}>
              <span style={{ fontSize:8, fontFamily:"monospace", color:"rgba(34,211,160,.35)" }}>
                ─ ─ NORMAL ≥ {THR_N} m/s
              </span>
              <span style={{ fontSize:8, fontFamily:"monospace", color:"rgba(239,68,68,.35)" }}>
                ─ ─ DANGER &lt; {THR_S} m/s
              </span>
            </div>
          </div>
        </div>
      </div>

      {/* ═══ TRACKING TABLE ══════════════════════════════════════ */}
      <div style={{ marginTop:12, background:"#080e18",
        border:"1px solid #0f1e2e", borderRadius:6, overflow:"hidden" }}>
        <div style={{ background:"#060b12", padding:"6px 12px", fontSize:8,
          color:"#2a4060", fontFamily:"monospace", letterSpacing:2,
          borderBottom:"1px solid #0f1e2e" }}>
          ▶ DEEPSORT TRACKING OUTPUT — REAL AI PIPELINE
        </div>
        <table style={{ width:"100%", borderCollapse:"collapse",
          fontFamily:"monospace", fontSize:11 }}>
          <thead>
            <tr>
              {["TRACK ID","SPEED","BBOX (x,y,w,h)","CROSSING %",
                "STATUS","∆ GREEN","GHOST"].map((h, i) => (
                <th key={i} style={{ padding:"6px 12px", textAlign:"left",
                  fontSize:8, letterSpacing:1, color:"#2a4060",
                  fontWeight:600, borderBottom:"1px solid #0f1e2e" }}>
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {tracks.length === 0 ? (
              <tr>
                <td colSpan={7} style={{ padding:"16px 12px", color:"#2a4060",
                  fontFamily:"monospace", fontSize:10, textAlign:"center" }}>
                  {wsStatus === "LIVE"
                    ? "No persons detected in frame"
                    : wsStatus === "CONNECTING"
                    ? "⌛ Waiting for backend…"
                    : "❌ Backend disconnected — run: python main.py"}
                </td>
              </tr>
            ) : (
              tracks.map((tr, i) => {
                const c   = colorOf(tr.speed);
                const st  = statusOf(tr.speed);
                const [bx, by, bw, bh] = tr.bbox;
                const extra = st === "DANGER" ? "+15s" : st === "SLOW" ? "+8s" : "—";
                // approximate crossing progress from bbox x center
                const prog = Math.min(100, Math.max(0,
                  Math.round(((bx + bw / 2) / (frameDims.width || 640)) * 100)));

                return (
                  <tr key={tr.id}
                    style={{ borderBottom:"1px solid #0a141c",
                      opacity: tr.confirmed === false ? 0.55 : 1 }}>
                    <td style={{ padding:"7px 12px", color:"#c0d8f0", fontWeight:700 }}>
                      {trackName(tr.id)}
                    </td>
                    <td style={{ padding:"7px 12px", color:c, fontWeight:700 }}>
                      {tr.speed.toFixed(2)} m/s
                    </td>
                    <td style={{ padding:"7px 12px", color:"#2a4060", fontSize:9 }}>
                      {bx},{by} {bw}×{bh}
                    </td>
                    <td style={{ padding:"7px 12px" }}>
                      <div style={{ display:"flex", alignItems:"center", gap:6 }}>
                        <div style={{ background:"#0c1520", borderRadius:2,
                          height:5, width:72, overflow:"hidden" }}>
                          <div style={{ height:"100%", width:`${prog}%`,
                            background:c, borderRadius:2,
                            transition:"width 0.3s" }}/>
                        </div>
                        <span style={{ color:"#2a4060", fontSize:8 }}>{prog}%</span>
                      </div>
                    </td>
                    <td style={{ padding:"7px 12px" }}>
                      <span style={{ color:c, border:`1px solid ${c}40`,
                        borderRadius:3, padding:"2px 7px", fontSize:8, letterSpacing:1,
                        animation: st === "DANGER" ? "_blink 0.8s infinite" : "none" }}>
                        {st === "DANGER" ? "⚠ " : st === "SLOW" ? "◆ " : "✓ "}{st}
                      </span>
                    </td>
                    <td style={{ padding:"7px 12px",
                      color: extra !== "—" ? "#f59e0b" : "#2a4060",
                      fontWeight: extra !== "—" ? 700 : 400 }}>
                      {extra}
                    </td>
                    <td style={{ padding:"7px 12px",
                      color: tr.confirmed === false ? "#f59e0b" : "#2a4060",
                      fontSize:9 }}>
                      {tr.confirmed === false ? "⏳ ghost" : "—"}
                    </td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>

      {/* Footer */}
      <div style={{ marginTop:10, display:"flex", justifyContent:"space-between",
        fontSize:8, fontFamily:"monospace", color:"#1a3050" }}>
        <span>THR: NORMAL ≥ {THR_N} m/s  |  SLOW ≥ {THR_S} m/s  |  DANGER &lt; {THR_S} m/s</span>
        <span>smaRRRt · B1228011 HENGTING LIU · B1228021 TINGYU CHIU</span>
      </div>
    </div>
  );
}
