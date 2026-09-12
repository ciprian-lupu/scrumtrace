# Local speaker analysis

FluidAudio 0.15.7 (Apache-2.0): https://github.com/FluidInference/FluidAudio/tree/0.15.7

Models are downloaded from https://huggingface.co/FluidInference/speaker-diarization-coreml and kept under Application Support/ScrumTrace/speaker-models. The original model cards and upstream notices govern those assets. They are not bundled with ScrumTrace. This app uses anonymous per-session segmentation/clustering, discards embeddings, and provides manual names and corrections.

Bundled dependency notices: FluidAudio, VBx, fastcluster and NemoTextProcessing (the SDK's text normalizer dependency, not used for speaker identification).
