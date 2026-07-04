// Passenger (cPanel Node.js Selector) entry point.
//
// Passenger requires a literal startup file that creates an HTTP server
// and listens on the port it assigns via process.env.PORT — `next start`
// alone doesn't satisfy that contract, so this wraps Next's programmatic
// API per https://nextjs.org/docs/app/guides/custom-server. Requires
// `next build` to have already run (production mode loads the build
// output from .next/, it does not build on the fly).
const { createServer } = require('http')
const next = require('next')

const dev = process.env.NODE_ENV !== 'production'
const port = parseInt(process.env.PORT, 10) || 3000
const app = next({ dev })
const handle = app.getRequestHandler()

app.prepare().then(() => {
  createServer((req, res) => {
    handle(req, res)
  }).listen(port, () => {
    console.log(`> Ready on port ${port}`)
  })
})
