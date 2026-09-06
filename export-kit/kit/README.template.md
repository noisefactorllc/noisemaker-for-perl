# {{NM_PROGRAM_NAME}}

This Perl distribution exports your Noisedeck program to render **on the CPU**. It requires no GPU, OpenGL, or XS. `engine/` contains the whole engine and uses core modules only. Perl executes the shader code as ordinary Perl, one pixel at a time. It fetches nothing at runtime.

With the required Perl interpreter already installed, this export needs no additional modules. It is a slow way to draw a frame. A GPU colors thousands of pixels at once. This renderer processes them one at a time.

## Run it

You need **Perl 5.22 or newer**. The engine requires no CPAN modules. Its imports, including `Compress::Zlib`, `JSON::PP` and `Digest::SHA`, all ship with Perl. Unzip this folder. Open a terminal in it. Start with a small image:

```sh
perl run.pl program.dsl --width 64 --height 64 --output out.png
```

The command writes a 64×64 `out.png` beside your program. This checks that the export works. Then increase the output size:

```sh
perl run.pl program.dsl --width 512 --height 512 --output art.png
```

Rendering time increases with the pixel count because pure Perl processes every pixel. Increase the size gradually. Expect large frames to take longer.

`--seed N` selects the deterministic seed. `--time N` sets the normalized time for effects that animate.
`perl run.pl --help` lists everything.

## What's inside

| Path | What it is |
| --- | --- |
| `run.pl` | The entry point. Puts `engine/lib` on the module path and renders. This is the file you run. |
| `program.dsl` | Your program's source, exactly as it was in Noisedeck. |
| `engine/lib/` | The engine: `Math::Fractal::Noisemaker` and everything under it. |
| `engine/bin/make-noise` | The port's own command line tool, with subcommands beyond rendering a file. |
| `noisedeck-export.json` | The exported content, export time, and engine build. |
| `LICENSES/` | Licenses for everything shipped here. |

The export installs nothing and writes nothing outside this folder. `run.pl` adds `engine/lib` with `use lib`, resolved from the script's own location. It works from any working directory. An installed `Math::Fractal::Noisemaker` cannot override the copy included with your program.

`engine/bin/make-noise` resolves `engine/lib` relative to itself, so it works from here too. It
renders one catalog effect at a time (`generate`, `apply`, `animate`) and takes a whole program on
standard input:

```sh
perl engine/bin/make-noise run --width 512 --height 512 --filename art.png < program.dsl
```

`perl engine/bin/make-noise --help` covers the rest. For the program sitting beside it, `run.pl` is
the shorter way to say the same thing.

## The engine

The export includes the port and runs offline without changes. It is also a normal distribution. `run.pl` calls two functions: `Math::Fractal::Noisemaker::Renderer::render_dsl($source, width => ..., height => ...)` and `Math::Fractal::Noisemaker::PNG::encode_png`. You can call them the same way from your own code. <https://github.com/noisefactorllc/noisemaker-for-perl> documents
the rest.

Noisedeck exported this program against Noisemaker `{{NM_ENGINE_VERSION}}`. The Perl port is a separate implementation of that engine. Expect small differences from the app output.

## Editing it

Replace `program.dsl` with a Noisemaker program that uses only the supported effects listed below. Run the same command again. To render several variations, call `render_dsl` in a loop in your own code. This avoids interpreter startup for each variation.

## Effects used by this program

{{NM_EFFECT_LIST}}

## What this port cannot render

This port cannot render five effects from the upstream catalog:

- `synth/roll`, `synth/scope` and `synth/spectrum` react to live audio.
- `render/meshLoader` and `render/meshRender` need a mesh pipeline.

Everything else in the catalog renders here.
`engine/lib/Math/Fractal/Noisemaker/bundle/metadata.json` lists exactly which effects this engine contains.

To check an edited `program.dsl` against a different build of this port:

1. Import the program into Noisedeck.
2. Open the export dialog.
3. Select Perl.

Before you export again, the dialog marks any effect the port cannot render.

## License

The Noisemaker engine and the Perl port are MIT licensed. See `LICENSES/`. Your program and the
imagery it renders are yours.
