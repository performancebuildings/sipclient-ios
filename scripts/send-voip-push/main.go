// Sends one VoIP push, for testing a wake by hand. The .p8 key stays on this machine.
//
//	go run scripts/send-voip-push/main.go -key AuthKey.p8 -key-id <key ID> \
//		-team-id <team ID> -bundle-id <bundle ID> -token <device token>
package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	keyPath := flag.String("key", "", "path to the .p8 file")
	keyID := flag.String("key-id", "", "APNs key ID")
	teamID := flag.String("team-id", "", "Apple Developer team ID")
	bundleID := flag.String("bundle-id", "", "the app's bundle ID; the topic is <bundle ID>.voip")
	token := flag.String("token", "", "device token, from the app's \"Push: token\" console line")
	production := flag.Bool("production", false, "use production APNs, for TestFlight installs")
	caller := flag.String("caller", "Door", "caller name shown by CallKit")
	age := flag.Duration("age", 0, "backdate sentAt by this much, to test a push past the ring window")
	flag.Parse()
	if *keyPath == "" || *keyID == "" || *teamID == "" || *bundleID == "" || *token == "" {
		flag.Usage()
		os.Exit(2)
	}

	jwt, err := providerToken(*keyPath, *keyID, *teamID)
	if err != nil {
		log.Fatal(err)
	}

	id, err := newUUID()
	if err != nil {
		log.Fatal(err)
	}
	payload, err := json.Marshal(map[string]any{
		"aps":    map[string]any{},
		"uuid":   id,
		"caller": *caller,
		"sentAt": time.Now().Add(-*age).UnixMilli(),
	})
	if err != nil {
		log.Fatal(err)
	}

	host := "api.sandbox.push.apple.com"
	if *production {
		host = "api.push.apple.com"
	}
	request, err := http.NewRequest(http.MethodPost, "https://"+host+"/3/device/"+*token, bytes.NewReader(payload))
	if err != nil {
		log.Fatal(err)
	}
	request.Header.Set("authorization", "bearer "+jwt)
	request.Header.Set("apns-push-type", "voip")
	request.Header.Set("apns-topic", *bundleID+".voip")
	request.Header.Set("apns-priority", "10")
	request.Header.Set("apns-id", id)
	request.Header.Set("apns-expiration", fmt.Sprint(time.Now().Add(10*time.Second).Unix()))

	client := http.Client{Timeout: 10 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		log.Fatal(err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	fmt.Printf("%s uuid %s %s\n", response.Status, id, body)
	if response.StatusCode != http.StatusOK {
		os.Exit(1)
	}
}

// providerToken signs the ES256 JWT that APNs expects.
func providerToken(keyPath, keyID, teamID string) (string, error) {
	data, err := os.ReadFile(keyPath)
	if err != nil {
		return "", err
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return "", fmt.Errorf("%s is not a PEM file", keyPath)
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return "", err
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return "", fmt.Errorf("%s is not an EC key", keyPath)
	}

	encode := base64.RawURLEncoding.EncodeToString
	header, err := json.Marshal(map[string]string{"alg": "ES256", "kid": keyID})
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(map[string]any{"iss": teamID, "iat": time.Now().Unix()})
	if err != nil {
		return "", err
	}
	unsigned := encode(header) + "." + encode(claims)

	digest := sha256.Sum256([]byte(unsigned))
	r, s, err := ecdsa.Sign(rand.Reader, key, digest[:])
	if err != nil {
		return "", err
	}
	signature := make([]byte, 64)
	r.FillBytes(signature[:32])
	s.FillBytes(signature[32:])
	return unsigned + "." + encode(signature), nil
}

func newUUID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:]), nil
}
