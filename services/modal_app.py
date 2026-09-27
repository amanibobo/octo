"""Modal deployment for the analysis service.

    cd services
    pip install modal && modal setup
    modal deploy modal_app.py          # prints the public URL → put it in the app's Info.plist (SounderAnalysisBaseURL)

`min_containers=1` keeps one warm container during the expo so the first
request never pays a cold start. CPU is enough for tables under ~10k rows.
"""

import modal

image = (
    modal.Image.debian_slim(python_version="3.12")
    .pip_install("fastapi", "uvicorn", "pydantic>=2.7", "numpy", "pandas", "scikit-learn", "scipy")
    .add_local_python_source("analysis")
    # The clinical package ships JSON data next to its code, so mount the whole folder.
    .add_local_dir("clinical", remote_path="/root/clinical")
)

app = modal.App("sounder-analysis", image=image)


@app.function(cpu=2.0, memory=2048, min_containers=1, timeout=120)
@modal.asgi_app()
def serve():
    from analysis.app import app as fastapi_app

    return fastapi_app
