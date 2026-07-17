# Function to create HTML template if it doesn't exist


# Function to generate HTML storage table
generate_html_storage_table() {
    if [ -z "$HTML_STORAGE_DATA" ]; then
        echo '<div class="no-data">No USB storage devices detected</div>'
    else
        echo '<table id="storageTable">'
        echo '<thead><tr>'
        echo '<th>Device</th><th>Capacity</th><th>USB Version</th><th>Speed</th><th>Model</th><th>Mount Point</th><th>Performance</th>'
        echo '</tr></thead><tbody>'
        echo "$HTML_STORAGE_DATA"
        echo '</tbody></table>'
    fi
}

# Function to generate HTML adapter table
generate_html_adapter_table() {
    if [ -z "$HTML_ADAPTER_DATA" ]; then
        echo '<div class="no-data">No USB adapters or devices detected</div>'
    else
        echo '<table id="adapterTable">'
        echo '<thead><tr>'
        echo '<th>Type</th><th>Vendor:Product</th><th>Model</th><th>USB Version</th><th>Speed</th><th>Device Path</th>'
        echo '</tr></thead><tbody>'
        echo "$HTML_ADAPTER_DATA"
        echo '</tbody></table>'
    fi
}

# Function to generate HTML controller list
generate_html_controller_list() {
    if [ -z "$HTML_CONTROLLER_DATA" ]; then
        echo '<div class="no-data">No USB controllers detected</div>'
    else
        echo "$HTML_CONTROLLER_DATA"
    fi
}

create_html_template() {
    HTML_TEMPLATE_FILE=$(mktemp /tmp/usb-inspector-template.XXXXXX) || {
        echo -e "${RED}❌ Cannot create HTML template file${NC}"
        exit 1
    }
    cat > "$HTML_TEMPLATE_FILE" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>USB Inspector Report - {{TIMESTAMP}}</title>
    <style>
        :root {
            --bg: #141019;
            --surface: #1c1524;
            --surface-2: #171120;
            --line: #372c44;
            --line-soft: rgba(255,255,255,0.06);
            --text: #e9e4f0;
            --muted: #a294b3;
            --cyan: #7cd6e8;
            --green: #8fdca4;
            --violet: #c9a6ff;
            --mono: ui-monospace, "SF Mono", "Cascadia Code", "JetBrains Mono",
                    "Fira Code", "DejaVu Sans Mono", Menlo, Consolas, monospace;
            --sans: system-ui, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
        }

        * { margin: 0; padding: 0; box-sizing: border-box; }

        body {
            font-family: var(--mono);
            background:
                radial-gradient(1100px 420px at 50% -10%, rgba(124,214,232,0.07), transparent 70%),
                var(--bg);
            min-height: 100vh;
            padding: 40px 20px 24px;
            color: var(--text);
            font-size: 14px;
            line-height: 1.5;
        }

        .container { max-width: 1100px; margin: 0 auto; }

        /* ── Nameplate ─────────────────────────────── */
        .header {
            background: linear-gradient(180deg, var(--surface), var(--surface-2));
            border: 1px solid var(--line);
            border-radius: 10px;
            margin-bottom: 28px;
            overflow: hidden;
        }

        .plate-head {
            display: flex;
            flex-wrap: wrap;
            gap: 12px 24px;
            align-items: baseline;
            justify-content: space-between;
            padding: 22px 26px 18px;
            border-bottom: 1px solid var(--line);
        }

        .eyebrow {
            font-family: var(--sans);
            font-size: 11px;
            letter-spacing: 0.22em;
            text-transform: uppercase;
            color: var(--cyan);
            margin-bottom: 6px;
        }

        h1 {
            font-size: 26px;
            font-weight: 600;
            letter-spacing: 0.03em;
        }

        .subtitle {
            color: var(--muted);
            font-size: 12.5px;
            text-align: right;
        }
        .subtitle span { display: block; }

        .stats-grid {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
        }

        .stat-card { padding: 18px 26px; }
        .stat-card + .stat-card { border-left: 1px solid var(--line); }

        .stat-number {
            font-size: 26px;
            font-weight: 600;
            color: var(--text);
        }

        .stat-label {
            font-family: var(--sans);
            color: var(--muted);
            font-size: 10.5px;
            margin-top: 4px;
            text-transform: uppercase;
            letter-spacing: 0.14em;
        }

        /* ── Sections ──────────────────────────────── */
        .section {
            background: var(--surface-2);
            border: 1px solid var(--line);
            border-radius: 10px;
            padding: 24px 26px;
            margin-bottom: 24px;
        }

        .section-eyebrow {
            font-family: var(--sans);
            font-size: 10.5px;
            letter-spacing: 0.22em;
            text-transform: uppercase;
            color: var(--muted);
        }

        .section-title {
            font-size: 18px;
            font-weight: 600;
            letter-spacing: 0.02em;
            margin: 4px 0 18px;
        }

        /* ── Tables ────────────────────────────────── */
        .table-scroll { overflow-x: auto; }

        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 16px;
        }

        th {
            font-family: var(--sans);
            padding: 8px 12px;
            text-align: left;
            font-weight: 600;
            font-size: 10.5px;
            letter-spacing: 0.14em;
            text-transform: uppercase;
            color: var(--muted);
            border-bottom: 1px solid var(--line);
            white-space: nowrap;
        }

        td {
            padding: 10px 12px;
            border-bottom: 1px solid var(--line-soft);
            font-size: 13px;
        }

        tbody tr { transition: background-color 0.15s; }
        tbody tr:hover { background-color: rgba(124,214,232,0.05); }

        /* USB generation badges — color encodes the generation */
        .usb-version {
            display: inline-block;
            padding: 2px 9px;
            border-radius: 999px;
            font-size: 11px;
            font-weight: 600;
            letter-spacing: 0.02em;
            color: var(--muted);
            border: 1px solid rgba(162,148,179,0.35);
            background: rgba(162,148,179,0.08);
            white-space: nowrap;
        }
        .usb-2-0            { color: #ecc94b; border-color: rgba(236,201,75,0.4);  background: rgba(236,201,75,0.08); }
        .usb-3-0-3-1-gen1   { color: #6aa9ff; border-color: rgba(106,169,255,0.4); background: rgba(106,169,255,0.08); }
        .usb-3-1-gen2       { color: #4ade80; border-color: rgba(74,222,128,0.4);  background: rgba(74,222,128,0.08); }
        .usb-3-2-gen2x2     { color: #c084fc; border-color: rgba(192,132,252,0.4); background: rgba(192,132,252,0.08); }
        .usb4               { color: #f472b6; border-color: rgba(244,114,182,0.4); background: rgba(244,114,182,0.08); }

        /* Performance */
        .performance-bar {
            width: 100%;
            min-width: 120px;
            height: 18px;
            background: rgba(255,255,255,0.07);
            border-radius: 4px;
            overflow: hidden;
        }

        .performance-fill {
            height: 100%;
            transition: width 1s ease;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #fff;
            font-weight: 600;
            font-size: 11px;
        }

        .excellent { background: #22c55e; }
        .good      { background: #ca9a04; }
        .fair      { background: #e4572e; }
        .poor      { background: #b91c1c; }

        /* Copyable chips */
        .mount-point, .device-path, .vendor-product {
            padding: 2px 7px;
            border-radius: 4px;
            font-size: 12px;
            white-space: nowrap;
        }
        .mount-point    { background: rgba(124,214,232,0.10); color: var(--cyan); }
        .device-path    { background: rgba(201,166,255,0.10); color: var(--violet); }
        .vendor-product { background: rgba(143,220,164,0.10); color: var(--green); }

        .no-data {
            text-align: center;
            padding: 40px;
            color: var(--muted);
            font-style: italic;
        }

        /* Search */
        .search-box { margin-bottom: 4px; }

        .search-input {
            width: 100%;
            padding: 9px 12px;
            background: var(--bg);
            border: 1px solid var(--line);
            border-radius: 6px;
            color: var(--text);
            font-family: var(--mono);
            font-size: 13px;
            transition: border-color 0.15s;
        }
        .search-input::placeholder { color: var(--muted); }
        .search-input:focus {
            outline: 2px solid rgba(124,214,232,0.45);
            outline-offset: 1px;
            border-color: var(--cyan);
        }

        .controller-card {
            background: var(--surface);
            border: 1px solid var(--line);
            border-left: 3px solid var(--cyan);
            padding: 12px 14px;
            margin-bottom: 10px;
            border-radius: 6px;
            font-size: 13px;
        }

        .footer {
            font-family: var(--sans);
            text-align: center;
            color: var(--muted);
            margin-top: 32px;
            font-size: 12px;
            letter-spacing: 0.04em;
        }

        @media (max-width: 768px) {
            body { padding: 20px 12px; }
            .stats-grid { grid-template-columns: repeat(2, 1fr); }
            .stat-card:nth-child(3) { border-left: none; }
            .stat-card:nth-child(n+3) { border-top: 1px solid var(--line); }
            .plate-head { flex-direction: column; }
            .subtitle { text-align: left; }
            th, td { padding: 8px; }
        }

        @media (prefers-reduced-motion: reduce) {
            * { transition: none !important; animation: none !important; }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="plate-head">
                <div>
                    <div class="eyebrow">Bus scan report</div>
                    <h1>USB Inspector</h1>
                </div>
                <div class="subtitle">
                    <span>{{TIMESTAMP}}</span>
                    <span>v5.0.1</span>
                </div>
            </div>
            <div class="stats-grid">
                <div class="stat-card">
                    <div class="stat-number">{{STORAGE_COUNT}}</div>
                    <div class="stat-label">Storage Devices</div>
                </div>
                <div class="stat-card">
                    <div class="stat-number">{{ADAPTER_COUNT}}</div>
                    <div class="stat-label">Adapters & Devices</div>
                </div>
                <div class="stat-card">
                    <div class="stat-number">{{TOTAL_CAPACITY}}</div>
                    <div class="stat-label">Total Capacity</div>
                </div>
                <div class="stat-card">
                    <div class="stat-number">{{CONTROLLER_COUNT}}</div>
                    <div class="stat-label">USB Controllers</div>
                </div>
            </div>
        </div>

        <div class="section">
            <div class="section-eyebrow">Block devices</div>
            <h2 class="section-title">USB Storage</h2>
            <div class="search-box">
                <input type="search" class="search-input" id="storageSearch" placeholder="Filter storage devices…">
            </div>
            <div class="table-scroll">
            {{STORAGE_TABLE}}
            </div>
        </div>

        <div class="section">
            <div class="section-eyebrow">Bus devices</div>
            <h2 class="section-title">USB Adapters &amp; Peripherals</h2>
            <div class="search-box">
                <input type="search" class="search-input" id="adapterSearch" placeholder="Filter adapters and devices…">
            </div>
            <div class="table-scroll">
            {{ADAPTER_TABLE}}
            </div>
        </div>

        <div class="section">
            <div class="section-eyebrow">Host</div>
            <h2 class="section-title">System USB Controllers</h2>
            {{CONTROLLER_LIST}}
        </div>

        <div class="footer">
            <p>Report generated in {{GENERATION_TIME}}s — performance data requires sudo</p>
        </div>
    </div>

    <script>
        // Search functionality
        function setupSearch(inputId, tableId) {
            const input = document.getElementById(inputId);
            const table = document.querySelector(tableId);

            if (input && table) {
                input.addEventListener('input', function() {
                    const filter = this.value.toLowerCase();
                    const rows = table.querySelectorAll('tbody tr');

                    rows.forEach(row => {
                        const text = row.textContent.toLowerCase();
                        row.style.display = text.includes(filter) ? '' : 'none';
                    });
                });
            }
        }

        // Initialize search boxes
        setupSearch('storageSearch', '#storageTable');
        setupSearch('adapterSearch', '#adapterTable');

        // Animate performance bars on load
        window.addEventListener('load', function() {
            const bars = document.querySelectorAll('.performance-fill');
            bars.forEach(bar => {
                const width = bar.style.width;
                bar.style.width = '0%';
                setTimeout(() => {
                    bar.style.width = width;
                }, 100);
            });
        });

        document.querySelectorAll('.device-path').forEach(elem => {
            elem.style.cursor = 'pointer';
            elem.title = 'Click to copy';
            elem.addEventListener('click', function() {
                // Ottieni il path completo dall'attributo data-full-path
                const fullPath = this.getAttribute('data-full-path');
                const textToCopy = fullPath || this.textContent;
                const originalDisplay = this.innerHTML;

                navigator.clipboard.writeText(textToCopy).then(() => {
                    // Mostra conferma di copia
                    this.innerHTML = '✓ Copied';
                    this.style.color = '#4ade80';

                    // Ripristina il contenuto originale dopo 1.5 secondi
                    setTimeout(() => {
                        this.innerHTML = originalDisplay;
                        this.style.color = '';
                    }, 1500);
                }).catch(err => {
                    // Fallback se clipboard API non disponibile
                    console.error('Failed to copy:', err);
                    const textArea = document.createElement('textarea');
                    textArea.value = textToCopy;
                    textArea.style.position = 'fixed';
                    textArea.style.left = '-999999px';
                    document.body.appendChild(textArea);
                    textArea.select();
                    try {
                        document.execCommand('copy');
                        this.innerHTML = '✓ Copied';
                        this.style.color = '#4ade80';
                        setTimeout(() => {
                            this.innerHTML = originalDisplay;
                            this.style.color = '';
                        }, 1500);
                    } catch (err2) {
                        console.error('Fallback copy failed:', err2);
                    }
                    document.body.removeChild(textArea);
                });
            });
        });

        document.querySelectorAll('.mount-point, .vendor-product').forEach(elem => {
            elem.style.cursor = 'pointer';
            elem.title = 'Click to copy';
            elem.addEventListener('click', function() {
                const text = this.textContent;
                navigator.clipboard.writeText(text).then(() => {
                    const original = this.textContent;
                    this.textContent = '✓ Copied!';
                    setTimeout(() => {
                        this.textContent = original;
                    }, 1000);
                });
            });
        });
    </script>
</body>
</html>
EOF
}
