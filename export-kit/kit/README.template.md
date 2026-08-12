# {{NM_PROGRAM_NAME}}

Your program, exported from Noisedeck as a Perl distribution that renders it **on the CPU**. No GPU,
no OpenGL, no XS: `engine/` is the whole engine, it uses core modules only, and Perl executes what
would normally be shader code as ordinary Perl, one pixel at a time. It fetches nothing at runtime.

That makes this the export that runs on a box where nothing is installed and nothing may be — and the
slow way to draw a frame. A GPU colors thousands of pixels at once; this walks them.

## Run it

You need **Perl 5.22 or newer**. No CPAN modules: the engine imports `Compress::Zlib`, `JSON::PP`,
`Digest::SHA` and friends, all of which ship with Perl. Unzip this folder, open a terminal in it, and
start small:

```sh
perl run.pl program.dsl --width 64 --height 64 --output out.png
```

That writes a 64×64 `out.png` beside your program, which is enough to prove the export works. Then
scale up:

```sh
perl run.pl program.dsl --width 512 --height 512 --output art.png
```

Time grows with the pixel count, and pure Perl walks every one of them, so raise the size in steps
and expect a large frame to take a while.

`--seed N` picks the deterministic seed and `--time N` the normalized time, for effects that animate.
`perl run.pl --help` lists everything.

## What's inside

| Path | What it is |
| --- | --- |
| `run.pl` | The entry point. Puts `engine/lib` on the module path and renders. This is the file you run. |
| `program.dsl` | Your program's source, exactly as Noisedeck had it. |
| `engine/lib/` | The engine: `Math::Fractal::Noisemaker` and everything under it. |
| `engine/bin/make-noise` | The port's own command line tool, with subcommands beyond rendering a file. |
| `noisedeck-export.json` | What was exported, when, against which engine build. |
| `LICENSES/` | Licenses for everything shipped here. |

Nothing is installed and nothing is written outside this folder. `run.pl` adds `engine/lib` with
`use lib`, resolved from the script's own location, so it works from any working directory and an
installed `Math::Fractal::Noisemaker` cannot shadow the one that shipped with your program.

`engine/bin/make-noise` resolves `engine/lib` relative to itself, so it works from here too. It
renders one catalog effect at a time (`generate`, `apply`, `animate`) and takes a whole program on
standard input:

```sh
perl engine/bin/make-noise run --width 512 --height 512 --filename art.png < program.dsl
```

`perl engine/bin/make-noise --help` covers the rest. For the program sitting beside it, `run.pl` is
the shorter way to say the same thing.

## The engine

The port ships inside this export, so it runs offline as it stands. It is also a normal distribution
— `Math::Fractal::Noisemaker::Renderer::render_dsl($source, width => ..., height => ...)` and
`Math::Fractal::Noisemaker::PNG::encode_png` are the two calls `run.pl` makes, and you can make them
the same way from your own code. <https://github.com/noisefactorllc/noisemaker-for-perl> documents
the rest.

Noisedeck exported this program against Noisemaker `{{NM_ENGINE_VERSION}}`. The Perl port is a second
implementation of that engine rather than the same code, so expect small differences from what the
app showed you.

## Editing it

Replace `program.dsl` with anything the Noisemaker language accepts, as long as its effects are in
the supported set below, and run the same command again. To render several variations, call
`render_dsl` in a loop of your own rather than paying interpreter startup each time.

## Effects used by this program

{{NM_EFFECT_LIST}}

## What this port cannot render

Five effects from the upstream catalog: `synth/roll`, `synth/scope` and `synth/spectrum`, which react
to live audio, and `render/meshLoader` and `render/meshRender`, which need a mesh pipeline. Everything
else in the catalog renders here, and `engine/lib/Math/Fractal/Noisemaker/bundle/metadata.json` lists
exactly what the engine in this folder carries.

To check an edited `program.dsl` against a different build of this port, put it back into Noisedeck
and open the export dialog with Perl selected: it marks any effect the port cannot render before you
export again.

## License

The Noisemaker engine and the Perl port are MIT licensed; see `LICENSES/`. Your program and the
imagery it renders are yours.
