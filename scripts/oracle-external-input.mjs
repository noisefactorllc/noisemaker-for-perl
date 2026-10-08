// Oracle-side external-input renderer for the reactive (MIDI/audio) and mesh
// (OBJ) parity cases.
//
// The noisemaker-cpu `effect` CLI binds no MIDI/audio/mesh fixture (its random
// pools exclude the external-input effects), so scripts/parity.pl renders the
// five reactive/mesh cases through the pinned oracle's own renderer instead:
// this script compiles a DSL program with the pinned oracle checkout's
// renderer (the same path the oracle's scripts/parity/run.js uses), feeding
// the oracle's own scripts/parity/reactive-fixtures.js fixtures via
// renderOptions.externalInputs, and writes the RGBA8 PNG that parity.pl
// compares against the Perl port's render of the same program.
//
// Usage: node scripts/oracle-external-input.mjs <effectId> <outPng> \
//          --width N --height N --seed N --time T   (DSL program on stdin)
//
// NOISEMAKER_CPU_DIR must point at the pinned oracle checkout (same contract
// as scripts/ParityOracle.pm). Exits 0 after writing the PNG; any failure exits
// nonzero with the error on stderr.

import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const cpuDir = process.env.NOISEMAKER_CPU_DIR
if (!cpuDir) {
  console.error('oracle-external-input: NOISEMAKER_CPU_DIR is not set')
  process.exit(2)
}

function parseArgs(argv) {
  const options = { effectId: argv[0], out: argv[1], width: 8, height: 8, seed: 1, time: 0.25 }
  for (let index = 2; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--width') options.width = Number(argv[++index])
    else if (argument === '--height') options.height = Number(argv[++index])
    else if (argument === '--seed') options.seed = Number(argv[++index])
    else if (argument === '--time') options.time = Number(argv[++index])
    else {
      console.error(`oracle-external-input: unknown option ${argument}`)
      process.exit(2)
    }
  }
  return options
}

const options = parseArgs(process.argv.slice(2))

const oracleIndex = pathToFileURL(join(cpuDir, 'src', 'index.js')).href
const oracleFixtures = pathToFileURL(join(cpuDir, 'scripts', 'parity', 'reactive-fixtures.js')).href
const oraclePng = pathToFileURL(join(cpuDir, 'src', 'node', 'png.js')).href

const [{ CpuRenderer, Surface, createDefaultRegistry, kernelFactories }, { externalInputsForCase }, { writePng }] =
  await Promise.all([import(oracleIndex), import(oracleFixtures), import(oraclePng)])

const source = readFileSync(0, 'utf8').replace(/\r\n/g, '\n')

const registry = createDefaultRegistry()
const renderer = new CpuRenderer({ registry, kernelFactories })
const blank = new Surface(options.width, options.height)
blank.format = 'rgba16f'

let rendered
try {
  rendered = renderer.render(source, {
    width: options.width,
    height: options.height,
    time: options.time,
    seed: options.seed,
    externalTextures: { imageTex: blank, textTex: blank },
    externalInputs: externalInputsForCase(options.effectId),
    oneShot: 'initial',
  })
} catch (error) {
  console.error(`oracle-external-input: ${options.effectId} failed: ${error.message}`)
  process.exit(1)
}

await writePng(options.out, rendered)
