module github.com/morzecrew/platform-images/images/mihomo/entrypoint

go 1.27

require github.com/morzecrew/platform-images/shared/go v0.0.0

// The shared module reaches the image build through the bake's named context
// `shared`, which the Dockerfile copies to the same relative place.
replace github.com/morzecrew/platform-images/shared/go => ../../../shared/go
