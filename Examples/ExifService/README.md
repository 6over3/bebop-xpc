# ExifService example

A Bebop RPC service that reads EXIF metadata from image files over XPC. The server runs as a launchd agent, the client sends file paths and gets back JSON.

## How it works

The Bebop schema (`exif.bop`) defines a single unary RPC:

```
service ExifService {
    Read(ReadRequest): ReadResponse;
}
```

The server registers as a Mach service via launchd. The client connects by name. Under the hood, [libexif](https://github.com/6over3/libexif) runs exiftool inside a WASM sandbox to extract metadata.

## Install

```sh
cd Examples/ExifService
make install
```

This builds a release binary, copies it to `/usr/local/bin`, and registers the launchd agent. The server starts immediately and stays running.

## Usage

```sh
ExifServiceExample photo.jpg sunset.png
```
## Uninstall

```sh
make uninstall
```

Stops the service, removes the binary, and deletes the plist.

## Regenerating the schema

If you change `exif.bop`, regenerate the Swift code:

```sh
bebopc build exif.bop -I ../../bebop/schemas --swift_out=Sources -D Services=both
```