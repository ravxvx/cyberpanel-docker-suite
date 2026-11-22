from django.urls import path
from . import assistant, views

# No app_name on purpose: the sidebar link uses the global route name 'dockerSuite'.
urlpatterns = [
    path("", views.dashboard, name="dockerSuite"),
    path("job/", views.job, name="dockerSuiteJob"),
    path("jobstatus/", views.jobstatus, name="dockerSuiteJobStatus"),
    path("overview/", views.overview, name="dockerSuiteOverview"),
    path("ai/chat/", assistant.ai_chat, name="dockerSuiteAiChat"),
    path("ai/exec/", assistant.ai_exec, name="dockerSuiteAiExec"),
    path("ai/settings/", assistant.ai_settings, name="dockerSuiteAiSettings"),
    path("ai/audit/", assistant.ai_audit, name="dockerSuiteAiAudit"),
    path("glpilatest/", views.glpilatest, name="dockerSuiteGlpiLatest"),
]
