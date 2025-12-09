const express = require('express');
const os = require('os');
const app = express();
const port = process.env.PORT || 3000;
const version = process.env.APP_VERSION || 'v1.0';

// Application state for health checks
let isReady = false;
let startTime = Date.now();
let requestCount = 0;
let errorCount = 0;

// Middleware to track requests
app.use((req, res, next) => {
  requestCount++;
  const start = Date.now();
  
  res.on('finish', () => {
    const duration = Date.now() - start;
    if (res.statusCode >= 400) {
      errorCount++;
    }
    
    // Log request (structured logging)
    console.log(JSON.stringify({
      timestamp: new Date().toISOString(),
      method: req.method,
      url: req.url,
      statusCode: res.statusCode,
      duration: duration,
      version: version,
      userAgent: req.get('User-Agent') || 'unknown'
    }));
  });
  
  next();
});

// Liveness probe - checks if the application is running
app.get('/health/live', (req, res) => {
  res.status(200).json({ 
    status: 'alive', 
    version: version,
    timestamp: new Date().toISOString(),
    uptime: Date.now() - startTime
  });
});

// Readiness probe - checks if the application is ready to serve traffic
app.get('/health/ready', (req, res) => {
  if (isReady) {
    res.status(200).json({ 
      status: 'ready', 
      version: version,
      timestamp: new Date().toISOString(),
      uptime: Date.now() - startTime,
      checks: {
        database: 'ok',
        dependencies: 'ok'
      }
    });
  } else {
    res.status(503).json({ 
      status: 'not ready', 
      version: version,
      timestamp: new Date().toISOString(),
      message: 'Application is starting up'
    });
  }
});

// Legacy health endpoint for backward compatibility
app.get('/health', (req, res) => {
  res.status(200).json({ 
    status: 'healthy', 
    version: version,
    timestamp: new Date().toISOString(),
    uptime: Date.now() - startTime
  });
});

// Main application endpoint - shows different content based on version
app.get('/', (req, res) => {
  const responses = {
    'v1.0': {
      message: 'Hello from STABLE version!',
      version: 'v1.0',
      color: 'blue',
      features: ['Basic functionality', 'Stable release']
    },
    'v2.0': {
      message: 'Hello from CANARY version!',
      version: 'v2.0', 
      color: 'green',
      features: ['Basic functionality', 'New feature', 'Enhanced UI']
    }
  };

  const response = responses[version] || responses['v1.0'];
  
  res.json({
    ...response,
    timestamp: new Date().toISOString(),
    hostname: require('os').hostname()
  });
});

// Prometheus-compatible metrics endpoint
app.get('/metrics', (req, res) => {
  const uptime = Date.now() - startTime;
  const memUsage = process.memoryUsage();
  
  res.set('Content-Type', 'text/plain');
  res.send(`# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total{version="${version}",method="GET"} ${requestCount}

# HELP http_request_errors_total Total HTTP request errors
# TYPE http_request_errors_total counter
http_request_errors_total{version="${version}"} ${errorCount}

# HELP app_uptime_seconds Application uptime in seconds
# TYPE app_uptime_seconds gauge
app_uptime_seconds{version="${version}"} ${uptime / 1000}

# HELP nodejs_memory_usage_bytes Node.js memory usage in bytes
# TYPE nodejs_memory_usage_bytes gauge
nodejs_memory_usage_bytes{type="rss",version="${version}"} ${memUsage.rss}
nodejs_memory_usage_bytes{type="heapTotal",version="${version}"} ${memUsage.heapTotal}
nodejs_memory_usage_bytes{type="heapUsed",version="${version}"} ${memUsage.heapUsed}
nodejs_memory_usage_bytes{type="external",version="${version}"} ${memUsage.external}

# HELP nodejs_version_info Node.js version information
# TYPE nodejs_version_info gauge
nodejs_version_info{version="${process.version}",app_version="${version}"} 1

# HELP app_info Application information
# TYPE app_info gauge
app_info{version="${version}",hostname="${os.hostname()}",platform="${os.platform()}"} 1
`);
});

// Version information endpoint
app.get('/version', (req, res) => {
  res.json({
    version: version,
    nodeVersion: process.version,
    hostname: os.hostname(),
    platform: os.platform(),
    arch: os.arch(),
    uptime: Date.now() - startTime,
    timestamp: new Date().toISOString()
  });
});

// Simulate application startup time
setTimeout(() => {
  isReady = true;
  console.log(`Application ${version} is ready to serve traffic`);
}, 2000);

app.listen(port, () => {
  console.log(JSON.stringify({
    timestamp: new Date().toISOString(),
    message: `Simple canary app ${version} listening on port ${port}`,
    version: version,
    port: port,
    hostname: os.hostname(),
    nodeVersion: process.version
  }));
});