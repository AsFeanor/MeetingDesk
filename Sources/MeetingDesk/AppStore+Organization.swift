import Foundation

extension AppStore {
    func loadWorkspaceCatalog() {
        do { workspaceCatalog = try WorkspaceCatalogStore(root: library.root).load() }
        catch { errorMessage = "Projeler okunamadı; kayıtlı dosya korundu. \(error.localizedDescription)" }
    }

    @discardableResult func createProject(name: String) -> UUID? {
        guard !workInProgress else { return nil }
        do {
            let project = MeetingProject(name: try WorkspaceCatalog.cleanName(name))
            var candidate = workspaceCatalog; candidate.projects.append(project)
            return saveWorkspaceCatalog(candidate) ? project.id : nil
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    @discardableResult func renameProject(id: UUID, name: String) -> Bool {
        guard !workInProgress, let index = workspaceCatalog.projects.firstIndex(where: { $0.id == id }) else { return false }
        do {
            var candidate = workspaceCatalog; candidate.projects[index].name = try WorkspaceCatalog.cleanName(name)
            return saveWorkspaceCatalog(candidate)
        } catch { errorMessage = error.localizedDescription; return false }
    }

    @discardableResult func deleteProject(id: UUID) -> Bool {
        guard !workInProgress, workspaceCatalog.projects.contains(where: { $0.id == id }) else { return false }
        guard !meetings.contains(where: { $0.projectID == id }), !workspaceCatalog.series.contains(where: { $0.projectID == id }) else {
            errorMessage = "Bu projeye bağlı toplantı veya seri var. Önce toplantıların bağını kaldır ve serileri sil."
            return false
        }
        var candidate = workspaceCatalog; candidate.projects.removeAll { $0.id == id }
        return saveWorkspaceCatalog(candidate)
    }

    @discardableResult func createSeries(name: String, projectID: UUID? = nil) -> UUID? {
        guard !workInProgress else { return nil }
        guard projectID == nil || workspaceCatalog.projects.contains(where: { $0.id == projectID }) else {
            errorMessage = "Seçilen proje artık kullanılamıyor."; return nil
        }
        do {
            let series = MeetingSeries(name: try WorkspaceCatalog.cleanName(name), projectID: projectID)
            var candidate = workspaceCatalog; candidate.series.append(series)
            return saveWorkspaceCatalog(candidate) ? series.id : nil
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    @discardableResult func renameSeries(id: UUID, name: String) -> Bool {
        guard !workInProgress, let index = workspaceCatalog.series.firstIndex(where: { $0.id == id }) else { return false }
        do {
            var candidate = workspaceCatalog; candidate.series[index].name = try WorkspaceCatalog.cleanName(name)
            return saveWorkspaceCatalog(candidate)
        } catch { errorMessage = error.localizedDescription; return false }
    }

    @discardableResult func deleteSeries(id: UUID) -> Bool {
        guard !workInProgress, workspaceCatalog.series.contains(where: { $0.id == id }) else { return false }
        guard !meetings.contains(where: { $0.seriesID == id }) else {
            errorMessage = "Bu seriye bağlı toplantılar var. Önce toplantıların seri bağını kaldır."; return false
        }
        var candidate = workspaceCatalog; candidate.series.removeAll { $0.id == id }
        return saveWorkspaceCatalog(candidate)
    }

    /// Membership is explicit. Selecting a project-owned series requires its exact project UUID.
    @discardableResult func assignMeeting(_ meetingID: UUID, projectID: UUID?, seriesID: UUID?,
                                         expectedMembership: MeetingOrganizationMembership? = nil) -> Bool {
        guard !workInProgress else { return false }
        let matches = meetings.filter { $0.id == meetingID }
        guard matches.count == 1, let current = matches.first else { return false }
        if let expectedMembership, expectedMembership != MeetingOrganizationMembership(meeting: current) {
            errorMessage = "Toplantının proje veya seri bağı değişti. Güncel bağları kontrol edip tekrar dene."
            return false
        }
        guard projectID == nil || workspaceCatalog.projects.contains(where: { $0.id == projectID }) else {
            errorMessage = "Seçilen proje artık kullanılamıyor."; return false
        }
        if let seriesID {
            guard let series = workspaceCatalog.series.first(where: { $0.id == seriesID }),
                  series.projectID == nil || series.projectID == projectID else {
                errorMessage = "Seçilen seri bu projeye ait değil. Proje ve seriyi yeniden seç."; return false
            }
        }
        // Loading before saving protects unreadable catalogs and stale external edits.
        do {
            guard try WorkspaceCatalogStore(root: library.root).load() == workspaceCatalog else {
                errorMessage = "Proje listesi değişti. Listeyi yeniden açıp tekrar dene."; return false
            }
        } catch { errorMessage = "Proje listesi okunamadı. \(error.localizedDescription)"; return false }
        return update(meetingID) { $0.projectID = projectID; $0.seriesID = seriesID }
    }

    @discardableResult func setGlobalWorkItemCompletion(_ row: GlobalWorkItem, isCompleted: Bool) -> Bool {
        guard canEditCarryover, GlobalWorkItems.isCurrent(row, in: meetings), isCompleted != row.isCompleted else { return false }
        return update(row.meetingID) { meeting in
            if isCompleted { meeting.completedActions.insert(row.action.id) }
            else { meeting.completedActions.remove(row.action.id) }
        }
    }

    private func saveWorkspaceCatalog(_ candidate: WorkspaceCatalog) -> Bool {
        do {
            try WorkspaceCatalogStore(root: library.root).save(candidate, replacing: workspaceCatalog)
            workspaceCatalog = candidate
            return true
        } catch { errorMessage = "Projeler kaydedilemedi: \(error.localizedDescription)"; return false }
    }
}
