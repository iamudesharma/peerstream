"""Generate original media for the macOS default-player integration test."""

import argparse
import pathlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="peerstream-fixture-") as directory:
        subtitles = []
        for language in ("English", "Hindi"):
            path = pathlib.Path(directory) / f"{language}.srt"
            path.write_text(
                f"1\n00:00:00,000 --> 00:01:00,000\n{language} subtitle fixture\n",
                encoding="utf-8",
            )
            subtitles.append(path)
        subprocess.run(
            [
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=60",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=60",
                "-f", "lavfi", "-i", "sine=frequency=880:duration=60",
                "-i", str(subtitles[0]), "-i", str(subtitles[1]),
                "-map", "0:v", "-map", "1:a", "-map", "2:a",
                "-map", "3:s", "-map", "4:s",
                "-c:v", "libx264", "-preset", "ultrafast", "-crf", "30",
                "-c:a:0", "libmp3lame", "-ac:a:0", "2", "-b:a:0", "64k",
                "-c:a:1", "ac3", "-ac:a:1", "6", "-b:a:1", "192k",
                "-c:s", "srt",
                "-metadata:s:a:0", "language=eng",
                "-metadata:s:a:0", "title=English audio",
                "-metadata:s:a:1", "language=hin",
                "-metadata:s:a:1", "title=Hindi audio",
                "-metadata:s:s:0", "language=eng",
                "-metadata:s:s:0", "title=English subtitles",
                "-metadata:s:s:1", "language=hin",
                "-metadata:s:s:1", "title=Hindi subtitles",
                "-disposition:s:0", "0", "-disposition:s:1", "0",
                str(args.output),
            ],
            check=True,
        )
    print(args.output.resolve())


if __name__ == "__main__":
    main()
