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
    rm -f $HTML_TEMPLATE_FILE
    if [ ! -f "$HTML_TEMPLATE_FILE" ] && [ $HTML_MODE -eq 1 ]; then
        cat > "$HTML_TEMPLATE_FILE" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>USB Inspector Report - {{TIMESTAMP}}</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
            color: #333;
        }

        .container {
            max-width: 1400px;
            margin: 0 auto;
        }

        .header {
            background: white;
            border-radius: 20px;
            padding: 30px;
            margin-bottom: 30px;
            box-shadow: 0 20px 40px rgba(0,0,0,0.1);
            text-align: center;
            position: relative;
            overflow: hidden;
        }

        .header::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            height: 5px;
            background: linear-gradient(90deg, #667eea, #764ba2, #f093fb);
            animation: gradient 3s ease infinite;
        }

        @keyframes gradient {
            0%, 100% { background-position: 0% 50%; }
            50% { background-position: 100% 50%; }
        }

        h1 {
            color: #667eea;
            font-size: 2.5em;
            margin-bottom: 10px;
            font-weight: 700;
        }

        .subtitle {
            color: #64748b;
            font-size: 1.1em;
        }

        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }

        .stat-card {
            background: white;
            border-radius: 15px;
            padding: 20px;
            box-shadow: 0 10px 25px rgba(0,0,0,0.08);
            transition: transform 0.3s, box-shadow 0.3s;
        }

        .stat-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 15px 35px rgba(0,0,0,0.15);
        }

        .stat-number {
            font-size: 2.5em;
            font-weight: 700;
            background: linear-gradient(135deg, #667eea, #764ba2);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }

        .stat-label {
            color: #64748b;
            font-size: 0.9em;
            margin-top: 5px;
            text-transform: uppercase;
            letter-spacing: 1px;
        }

        .section {
            background: white;
            border-radius: 20px;
            padding: 30px;
            margin-bottom: 30px;
            box-shadow: 0 20px 40px rgba(0,0,0,0.1);
        }

        .section-title {
            font-size: 1.8em;
            color: #334155;
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 3px solid #e2e8f0;
            display: flex;
            align-items: center;
            gap: 10px;
        }

        .icon {
            font-size: 1.2em;
        }

        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 20px;
        }

        thead {
            background: linear-gradient(135deg, #667eea, #764ba2);
            color: white;
        }

        th {
            padding: 15px;
            text-align: left;
            font-weight: 600;
            letter-spacing: 0.5px;
        }

        td {
            padding: 12px 15px;
            border-bottom: 1px solid #e2e8f0;
        }

        tbody tr {
            transition: background-color 0.3s;
        }

        tbody tr:hover {
            background-color: #f8fafc;
        }

        .usb-version {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 20px;
            font-weight: 600;
            font-size: 0.85em;
        }

        .usb-1-0 { background: #e2e8f0; color: #475569; }
        .usb-1-1 { background: #e2e8f0; color: #475569; }
        .usb-2-0 { background: #fef3c7; color: #92400e; }
        .usb-3-0-3-1-gen1 { background: #dbeafe; color: #1e40af; } /* Aggiorna questa riga */
        .usb-3-1-gen2 { background: #d1fae5; color: #065f46; }
        .usb-3-2 { background: #e9d5ff; color: #6b21a8; }
        .usb-4 { background: #fce7f3; color: #9f1239; }

        .performance-bar {
            width: 100%;
            height: 24px;
            background: #e2e8f0;
            border-radius: 12px;
            overflow: hidden;
            position: relative;
        }

        .performance-fill {
            height: 100%;
            border-radius: 12px;
            transition: width 1s ease;
            display: flex;
            align-items: center;
            justify-content: center;
            color: white;
            font-weight: 600;
            font-size: 0.85em;
        }

        .excellent { background: linear-gradient(90deg, #10b981, #34d399); }
        .good { background: linear-gradient(90deg, #f59e0b, #fbbf24); }
        .fair { background: linear-gradient(90deg, #ef4444, #f87171); }
        .poor { background: linear-gradient(90deg, #991b1b, #dc2626); }

        .mount-point {
            background: #f0f9ff;
            color: #0369a1;
            padding: 4px 8px;
            border-radius: 6px;
            font-family: monospace;
            font-size: 0.9em;
        }

        .device-path {
            background: #fdf4ff;
            color: #a21caf;
            padding: 4px 8px;
            border-radius: 6px;
            font-family: monospace;
            font-size: 0.9em;
        }

        .vendor-product {
            background: #f0fdf4;
            color: #14532d;
            padding: 4px 8px;
            border-radius: 6px;
            font-family: monospace;
            font-size: 0.9em;
        }

        .no-data {
            text-align: center;
            padding: 40px;
            color: #94a3b8;
            font-style: italic;
        }

        .footer {
            text-align: center;
            color: white;
            margin-top: 40px;
            padding: 20px;
            opacity: 0.9;
        }

        .search-box {
            margin-bottom: 20px;
            position: relative;
        }

        .search-input {
            width: 100%;
            padding: 12px 20px 12px 45px;
            border: 2px solid #e2e8f0;
            border-radius: 10px;
            font-size: 1em;
            transition: border-color 0.3s;
        }

        .search-input:focus {
            outline: none;
            border-color: #667eea;
        }

        .search-icon {
            position: absolute;
            left: 15px;
            top: 50%;
            transform: translateY(-50%);
            color: #94a3b8;
        }

        .controller-card {
            background: #fafafa;
            border-left: 4px solid #667eea;
            padding: 15px;
            margin-bottom: 10px;
            border-radius: 8px;
            font-family: monospace;
        }

        @media (max-width: 768px) {
            .stats-grid {
                grid-template-columns: 1fr;
            }
            
            h1 {
                font-size: 1.8em;
            }
            
            table {
                font-size: 0.9em;
            }
            
            th, td {
                padding: 8px;
            }
        }

        .animated-bg {
            position: fixed;
            width: 100%;
            height: 100%;
            top: 0;
            left: 0;
            z-index: -1;
            background: linear-gradient(270deg, #667eea, #764ba2, #f093fb);
            background-size: 600% 600%;
            animation: gradientShift 15s ease infinite;
        }

        @keyframes gradientShift {
            0% { background-position: 0% 50%; }
            50% { background-position: 100% 50%; }
            100% { background-position: 0% 50%; }
        }
    </style>
</head>
<body>
    <div class="animated-bg"></div>
    <div class="container">
        <div class="header">
            <h1>🔍 USB Inspector Report</h1>
            <div class="subtitle">Generated on {{TIMESTAMP}}</div>
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

        <div class="section">
            <h2 class="section-title">
                <span class="icon">💾</span>
                USB Storage Devices
            </h2>
            <div class="search-box">
                <span class="search-icon">🔍</span>
                <input type="text" class="search-input" id="storageSearch" placeholder="Search storage devices...">
            </div>
            {{STORAGE_TABLE}}
        </div>

        <div class="section">
            <h2 class="section-title">
                <span class="icon">🔌</span>
                USB Adapters & Other Devices
            </h2>
            <div class="search-box">
                <span class="search-icon">🔍</span>
                <input type="text" class="search-input" id="adapterSearch" placeholder="Search adapters and devices...">
            </div>
            {{ADAPTER_TABLE}}
        </div>

        <div class="section">
            <h2 class="section-title">
                <span class="icon">🎛️</span>
                System USB Controllers
            </h2>
            {{CONTROLLER_LIST}}
        </div>

        <div class="footer">
            <p>USB Inspector v5.0 © 2025 | Performance data requires sudo privileges</p>
            <p>Report generated in {{GENERATION_TIME}} seconds</p>
        </div>
    </div>

    <script>
        // Search functionality
        function setupSearch(inputId, tableId) {
            const input = document.getElementById(inputId);
            const table = document.querySelector(tableId);
            
            if (input && table) {
                input.addEventListener('keyup', function() {
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
                
                navigator.clipboard.writeText(textToCopy).then(() => {
                    // Salva il contenuto originale visualizzato
                    const originalDisplay = this.innerHTML;
                    // Mostra conferma di copia
                    this.innerHTML = '✓ Copied';
                    this.style.color = '#10b981'; // Verde per conferma
                    
                    // Ripristina il contenuto originale dopo 1.5 secondi
                    setTimeout(() => {
                        this.innerHTML = originalDisplay;
                        this.style.color = ''; // Ripristina colore originale
                    }, 1500);
                }).catch(err => {
                    // Fallback se clipboard API non disponibile
                    console.error('Failed to copy:', err);
                    // Prova metodo alternativo
                    const textArea = document.createElement('textarea');
                    textArea.value = textToCopy;
                    textArea.style.position = 'fixed';
                    textArea.style.left = '-999999px';
                    document.body.appendChild(textArea);
                    textArea.select();
                    try {
                        document.execCommand('copy');
                        this.innerHTML = '✓ Copied';
                        this.style.color = '#10b981';
                        setTimeout(() => {
                            this.innerHTML = originalDisplay;
                            this.style.color = '';
                        }, 1500);
                    } catch (err) {
                        console.error('Fallback copy failed:', err);
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
        echo -e "${GREEN}✓ HTML template created at: $HTML_TEMPLATE_FILE${NC}"
    fi
}