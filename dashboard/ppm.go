package main

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
	"io"
	"strconv"
	"strings"
)

func decodePPM(ppm []byte) (*image.NRGBA, int, int, error) {
	r := bufio.NewReader(bytes.NewReader(ppm))
	magic, err := readPPMToken(r)
	if err != nil {
		return nil, 0, 0, fmt.Errorf("read ppm magic: %w", err)
	}
	if magic != "P6" {
		return nil, 0, 0, fmt.Errorf("unsupported ppm magic %q (want P6)", magic)
	}
	wStr, err := readPPMToken(r)
	if err != nil {
		return nil, 0, 0, fmt.Errorf("read ppm width: %w", err)
	}
	hStr, err := readPPMToken(r)
	if err != nil {
		return nil, 0, 0, fmt.Errorf("read ppm height: %w", err)
	}
	maxStr, err := readPPMToken(r)
	if err != nil {
		return nil, 0, 0, fmt.Errorf("read ppm maxval: %w", err)
	}
	w, err := strconv.Atoi(wStr)
	if err != nil || w <= 0 || w > 16384 {
		return nil, 0, 0, fmt.Errorf("invalid ppm width %q", wStr)
	}
	h, err := strconv.Atoi(hStr)
	if err != nil || h <= 0 || h > 16384 {
		return nil, 0, 0, fmt.Errorf("invalid ppm height %q", hStr)
	}
	maxVal, err := strconv.Atoi(maxStr)
	if err != nil || maxVal != 255 {
		return nil, 0, 0, fmt.Errorf("unsupported ppm maxval %q", maxStr)
	}
	rgbLen := w * h * 3
	rgb := make([]byte, rgbLen)
	if _, err := io.ReadFull(r, rgb); err != nil {
		return nil, 0, 0, fmt.Errorf("read ppm pixels (%dx%d): %w", w, h, err)
	}
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	pix := img.Pix
	for i, j := 0, 0; i < rgbLen; i, j = i+3, j+4 {
		pix[j] = rgb[i]
		pix[j+1] = rgb[i+1]
		pix[j+2] = rgb[i+2]
		pix[j+3] = 0xff
	}
	return img, w, h, nil
}

func encodePPMToPNG(ppm []byte) ([]byte, int, int, error) {
	img, w, h, err := decodePPM(ppm)
	if err != nil {
		return nil, 0, 0, err
	}
	var out bytes.Buffer
	enc := png.Encoder{CompressionLevel: png.BestSpeed}
	if err := enc.Encode(&out, img); err != nil {
		return nil, 0, 0, fmt.Errorf("encode png: %w", err)
	}
	return out.Bytes(), w, h, nil
}

// encodePPMToJPEG downscales by 2x when requested for ultra-fast MJPEG browser streaming.
func encodePPMToJPEG(ppm []byte, quality int, halfScale bool) ([]byte, int, int, error) {
	img, w, h, err := decodePPM(ppm)
	if err != nil {
		return nil, 0, 0, err
	}
	var target image.Image = img
	outW, outH := w, h
	if halfScale && w >= 540 && h >= 1000 {
		outW, outH = w/2, h/2
		scaled := image.NewNRGBA(image.Rect(0, 0, outW, outH))
		src := img.Pix
		dst := scaled.Pix
		for y := 0; y < outH; y++ {
			sy := y * 2 * img.Stride
			dy := y * scaled.Stride
			for x := 0; x < outW; x++ {
				si := sy + x*8
				di := dy + x*4
				dst[di] = src[si]
				dst[di+1] = src[si+1]
				dst[di+2] = src[si+2]
				dst[di+3] = 0xff
			}
		}
		target = scaled
	}
	var out bytes.Buffer
	if quality <= 0 || quality > 100 {
		quality = 78
	}
	if err := jpeg.Encode(&out, target, &jpeg.Options{Quality: quality}); err != nil {
		return nil, 0, 0, fmt.Errorf("encode jpeg: %w", err)
	}
	return out.Bytes(), outW, outH, nil
}

func readPPMToken(r *bufio.Reader) (string, error) {
	var tok strings.Builder
	for {
		b, err := r.ReadByte()
		if err != nil {
			if errors.Is(err, io.EOF) && tok.Len() > 0 {
				return tok.String(), nil
			}
			return "", err
		}
		if b == '#' && tok.Len() == 0 {
			for {
				c, err := r.ReadByte()
				if err != nil || c == '\n' {
					break
				}
			}
			continue
		}
		if b == ' ' || b == '\t' || b == '\r' || b == '\n' {
			if tok.Len() > 0 {
				return tok.String(), nil
			}
			continue
		}
		tok.WriteByte(b)
	}
}
