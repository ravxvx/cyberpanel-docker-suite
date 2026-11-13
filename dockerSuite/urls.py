from django.urls import path
from . import views

# No app_name on purpose: the sidebar link uses the global route name 'dockerSuite'.
urlpatterns = [
    path("", views.dashboard, name="dockerSuite"),
    path("job/", views.job, name="dockerSuiteJob"),
    path("jobstatus/", views.jobstatus, name="dockerSuiteJobStatus"),
    path("overview/", views.overview, name="dockerSuiteOverview"),
    path("glpilatest/", views.glpilatest, name="dockerSuiteGlpiLatest"),
]
